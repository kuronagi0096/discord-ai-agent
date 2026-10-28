// Discord のボタンで答えられるようにする。
//   A. 許可の確認 … プラグインは DM にだけ英語のボタンを送る。これを、作業しているチャンネルに日本語＋中身つきで出す。
//                    チャンネルが決まらないとき・送れなかったときは、プラグインのもとの動き（DM）に任せる。
//   B. ask_choice … Claude が選択肢の質問をボタンで出す道具。押された答えは、ふつうのメッセージと同じ形で Claude に届く。
//
// discord プラグインの server.ts に apply-plugin-patch.ts が 1 行足し（mcp.connect の直前）、attach(...) が呼ばれる。
// プラグインの MCP サーバーに登録済みのハンドラーを包んで足している（MCP SDK の _requestHandlers / _notificationHandlers）。
// discord.js はここから読み込めないので、ボタンは Discord API の形（type 1 / 2）のまま書く。

import { readFileSync } from 'fs'
import { join } from 'path'
import { randomBytes } from 'crypto'
import { excerpt, isDelivered, readStatus, writeStatus } from './status-presence.ts'

const PERM_REQUEST = 'notifications/claude/channel/permission_request'
const MAX_OPTIONS = 10
const MSG_LIMIT = 2000

const BUTTON_ROW = 1, BUTTON = 2
const STYLE_PRIMARY = 1, STYLE_SECONDARY = 2, STYLE_SUCCESS = 3, STYLE_DANGER = 4

const ASK_TOOL = {
  name: 'ask_choice',
  description:
    'Ask the Discord user a multiple-choice question shown as buttons. Use this instead of AskUserQuestion — that one only appears in the local terminal, which the Discord user cannot see. ' +
    'After calling it, end your turn: the chosen option arrives later as a new <channel> message. The user may also type a free-form answer instead of pressing a button.',
  inputSchema: {
    type: 'object',
    properties: {
      chat_id: { type: 'string', description: 'chat_id from the inbound <channel> message.' },
      question: { type: 'string' },
      options: {
        type: 'array',
        items: { type: 'string' },
        description: `2 to ${MAX_OPTIONS} short choices (button labels, max 80 characters each).`,
      },
    },
    required: ['chat_id', 'question', 'options'],
  },
}

const INSTRUCTIONS =
  '\n\nWhen you need the Discord user to pick between options, call ask_choice (buttons on Discord) rather than AskUserQuestion, then end your turn and wait for their answer.'

function loadAccess(stateDir: string): any {
  try { return JSON.parse(readFileSync(join(stateDir, 'access.json'), 'utf8')) } catch { return {} }
}

function fence(s: string): string {
  return '```\n' + s.replace(/```/g, 'ʼʼʼ') + '\n```'
}

function clip(s: string, max: number): string {
  return s.length > max ? s.slice(0, max - 1) + '…' : s
}

function permText(tool_name: string, description: string, input_preview: string): string {
  let input = input_preview
  try { input = JSON.stringify(JSON.parse(input_preview), null, 2) } catch {}
  const head = `🔐 **許可の確認**：${tool_name}\n${description ? clip(description, 300) + '\n' : ''}`
  return head + fence(clip(input, MSG_LIMIT - head.length - 20))
}

function rows(buttons: any[]): any[] {
  const out: any[] = []
  for (let i = 0; i < buttons.length; i += 5) out.push({ type: BUTTON_ROW, components: buttons.slice(i, i + 5) })
  return out
}

export function attach(mcp: any, client: any, stateDir: string, fetchAllowedChannel: (id: string) => Promise<any>): void {
  let lastChat: string | undefined
  const asks = new Map<string, { question: string; options: string[] }>()

  client.on('messageCreate', (msg: any) => {
    if (isDelivered(stateDir, msg)) lastChat = msg.channelId
  })

  // 許可のボタンを出すチャンネル：最後にメッセージが来たチャンネル。まだなければ、登録が 1 つだけならそこ
  const permChannel = (): string | undefined => {
    if (lastChat) return lastChat
    const groups = Object.keys(loadAccess(stateDir).groups ?? {})
    return groups.length === 1 ? groups[0] : undefined
  }

  const setStatus = (s: Parameters<typeof writeStatus>[1]) => { try { writeStatus(stateDir, s) } catch {} }

  // ---------- A. 許可の確認をチャンネルに出す ----------

  const origPerm = mcp._notificationHandlers.get(PERM_REQUEST)
  mcp._notificationHandlers.set(PERM_REQUEST, async (n: any) => {
    const p = n?.params ?? {}
    const chatId = permChannel()
    try {
      if (!chatId || !/^[a-km-z]{5}$/.test(p.request_id ?? '')) throw new Error('no channel')
      const ch = await fetchAllowedChannel(chatId)
      await ch.send({
        content: permText(p.tool_name ?? '', p.description ?? '', p.input_preview ?? ''),
        components: rows([
          { type: BUTTON, style: STYLE_SUCCESS, label: '許可', emoji: { name: '✅' }, custom_id: `dc:perm:allow:${p.request_id}` },
          { type: BUTTON, style: STYLE_DANGER, label: '拒否', emoji: { name: '❌' }, custom_id: `dc:perm:deny:${p.request_id}` },
        ]),
      })
    } catch (e) {
      if (String(e) !== 'Error: no channel') process.stderr.write(`discord buttons: permission to channel failed, using DM: ${e}\n`)
      return origPerm?.(n)
    }
  })

  // ---------- B. ask_choice ----------

  const origList = mcp._requestHandlers.get('tools/list')
  const origCall = mcp._requestHandlers.get('tools/call')
  mcp._requestHandlers.set('tools/list', async (req: any, extra: any) => {
    const r = await origList(req, extra)
    return { ...r, tools: [...(r.tools ?? []), ASK_TOOL] }
  })
  mcp._requestHandlers.set('tools/call', async (req: any, extra: any) => {
    if (req.params?.name !== ASK_TOOL.name) return origCall(req, extra)
    try {
      const a = req.params.arguments ?? {}
      const options: string[] = (Array.isArray(a.options) ? a.options : []).map((o: unknown) => String(o).trim()).filter(Boolean)
      if (options.length < 2 || options.length > MAX_OPTIONS) throw new Error(`options must have 2 to ${MAX_OPTIONS} items`)
      const question = String(a.question ?? '').trim()
      if (!question) throw new Error('question is required')
      const ch = await fetchAllowedChannel(String(a.chat_id))
      const id = randomBytes(4).toString('hex')
      asks.set(id, { question, options })
      const sent = await ch.send({
        content: clip(`❓ ${question}`, MSG_LIMIT),
        components: rows(options.map((o, i) => ({
          type: BUTTON, style: i === 0 ? STYLE_PRIMARY : STYLE_SECONDARY, label: clip(o, 80), custom_id: `dc:ask:${id}:${i}`,
        }))),
      })
      setStatus({ state: 'waiting', text: excerpt(question), ask: true })
      return {
        content: [{ type: 'text', text: `posted question with ${options.length} buttons (message_id ${sent.id}). End your turn now; the answer arrives as a new <channel> message.` }],
      }
    } catch (e) {
      return { content: [{ type: 'text', text: `ask_choice failed: ${e instanceof Error ? e.message : e}` }], isError: true }
    }
  })

  if (typeof mcp._instructions === 'string') mcp._instructions += INSTRUCTIONS

  // ---------- ボタンが押されたとき ----------

  client.on('interactionCreate', async (it: any) => {
    if (!it.isButton?.() || !String(it.customId).startsWith('dc:')) return
    if (!(loadAccess(stateDir).allowFrom ?? []).includes(it.user.id)) {
      await it.reply({ content: '押せるのは登録された人だけです。', ephemeral: true }).catch(() => {})
      return
    }

    const perm = /^dc:perm:(allow|deny):([a-km-z]{5})$/.exec(it.customId)
    if (perm) {
      const [, behavior, request_id] = perm
      void mcp.notification({ method: 'notifications/claude/channel/permission', params: { request_id, behavior } })
      const label = behavior === 'allow' ? '✅ 許可しました' : '❌ 拒否しました'
      await it.update({ content: clip(`${it.message.content}\n${label}`, MSG_LIMIT), components: [] }).catch(() => {})
      setStatus({ state: 'working', text: readStatus(stateDir).text })
      return
    }

    const ask = /^dc:ask:([0-9a-f]{8}):(\d+)$/.exec(it.customId)
    if (ask) {
      const q = asks.get(ask[1])
      const choice = q?.options[Number(ask[2])]
      if (!q || choice === undefined) {
        await it.reply({ content: 'この質問は答え済みか、ボットが起動し直されたため受け付けられません。必要なら文字で答えてください。', ephemeral: true }).catch(() => {})
        return
      }
      asks.delete(ask[1])
      await it.update({ content: clip(`${it.message.content}\n→ **${choice}**`, MSG_LIMIT), components: [] }).catch(() => {})
      setStatus({ state: 'working', text: excerpt(choice) })
      void mcp.notification({
        method: 'notifications/claude/channel',
        params: {
          content: `「${q.question}」への回答：${choice}`,
          meta: {
            chat_id: it.channelId,
            message_id: it.message.id,
            user: it.user.username,
            user_id: it.user.id,
            ts: new Date().toISOString(),
          },
        },
      }).catch((e: unknown) => process.stderr.write(`discord buttons: failed to deliver answer: ${e}\n`))
    }
  })

  process.stderr.write('discord buttons: attached\n')
}
