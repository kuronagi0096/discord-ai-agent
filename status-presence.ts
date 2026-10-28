// ボットのステータス（カスタムステータスの吹き出しとオンラインの色）を、作業の状態に合わせて変える。
//
// discord プラグインの server.ts に apply-plugin-patch.ts が 1 行足し、そこから attach(client, STATE_DIR) が呼ばれる。
// 状態は <STATE_DIR>\status.json に書く：
//   - 受け取ったメッセージ … このファイル自身が書く（作業中＋本文の頭）
//   - 指示を受けた・確認待ち・終わった … Claude Code のフック（status-hook.ts）が書く
//   - 選択肢の質問を出した・答えた … discord-buttons.ts が書く（ask: true の確認待ちは、返事が終わっても消さない）
// discord.js はここから読み込めない（node_modules がプラグイン側にある）ので、client は引数でもらい、定数は数値で書く。

import { readFileSync, writeFileSync, renameSync } from 'fs'
import { join } from 'path'

const ACTIVITY_CUSTOM = 4                // ActivityType.Custom
const MIN_INTERVAL_MS = 5000             // ステータスの変更は回数制限があるので、最短でもこの間隔をあける
const POLL_MS = 1000
const PERMISSION_REPLY_RE = /^\s*(y|yes|n|no)\s+([a-km-z]{5})\s*$/i   // server.ts と同じ。許可の返事は作業の始まりではない

type State = 'working' | 'waiting' | 'idle'
export type Status = { state: State; text?: string; step?: string; ask?: boolean; at?: number }

const STATUS_LIMIT = 128   // カスタムステータスの文字数の上限

export function excerpt(s: string, max = 40): string {
  const t = s.replace(/<a?:(\w+):\d+>/g, ':$1:').replace(/<[@#][!&]?\d+>/g, '').replace(/\s+/g, ' ').trim()
  return t.length > max ? t.slice(0, max - 1) + '…' : t
}

export function writeStatus(stateDir: string, status: Status): void {
  const f = join(stateDir, 'status.json')
  const tmp = f + '.tmp'
  writeFileSync(tmp, JSON.stringify({ ...status, at: Date.now() }))
  renameSync(tmp, f)
}

export function readStatus(stateDir: string): Status {
  try { return JSON.parse(readFileSync(join(stateDir, 'status.json'), 'utf8')) } catch { return { state: 'idle' } }
}

// 作業中は「⏳ 今の一手｜指示の頭」、一手がまだなければ「⏳ 作業中：指示の頭」
function toPresence(s: Status) {
  const custom = (text: string) => [{ type: ACTIVITY_CUSTOM, name: 'Custom Status', state: excerpt(text, STATUS_LIMIT) }]
  switch (s.state) {
    case 'working':
      return { status: 'dnd', activities: custom(s.step ? `⏳ ${s.step}${s.text ? '｜' + s.text : ''}` : '⏳ 作業中' + (s.text ? '：' + s.text : '')) }
    case 'waiting':
      return { status: 'idle', activities: custom('❓ 確認待ち' + (s.text ? '：' + s.text : '')) }
    default:
      return { status: 'online', activities: [] }
  }
}

// プラグインが Claude に渡すメッセージか（server.ts の gate() / isMentioned() を、許可リストと @ のぶんだけまねたもの）
export function isDelivered(stateDir: string, msg: any, client: any): boolean {
  if (msg.author?.bot) return false
  if (PERMISSION_REPLY_RE.test(msg.content ?? '')) return false
  try {
    const access = JSON.parse(readFileSync(join(stateDir, 'access.json'), 'utf8'))
    const sender = msg.author.id
    if (!msg.guildId) return (access.allowFrom ?? []).includes(sender)
    const channelId = msg.channel?.isThread?.() ? msg.channel.parentId ?? msg.channelId : msg.channelId
    const g = access.groups?.[channelId]
    if (!g) return false
    if (g.allowFrom?.length && !g.allowFrom.includes(sender)) return false
    if (g.requireMention ?? true) return isMentioned(msg, client, access.mentionPatterns)
    return true
  } catch { return false }
}

function isMentioned(msg: any, client: any, patterns?: string[]): boolean {
  const me = client?.user
  if (me && msg.mentions?.has?.(me)) return true
  if (me && msg.mentions?.repliedUser?.id === me.id) return true   // ボットへの返信
  for (const p of patterns ?? []) {
    try { if (new RegExp(p, 'i').test(msg.content ?? '')) return true } catch {}
  }
  return false
}

export function attach(client: any, stateDir: string): void {
  let applied = ''                 // 最後に Discord へ送った内容
  let lastSent = 0

  const apply = () => {
    if (!client.user) return
    const p = toPresence(readStatus(stateDir))
    const key = JSON.stringify(p)
    if (key === applied) return
    if (Date.now() - lastSent < MIN_INTERVAL_MS) return   // 次の見回りで最新の状態を送る
    try {
      client.user.setPresence(p)
      applied = key
      lastSent = Date.now()
    } catch (e) {
      process.stderr.write(`discord status: setPresence failed: ${e}\n`)
    }
  }

  client.on('messageCreate', (msg: any) => {
    if (!isDelivered(stateDir, msg, client)) return
    const text = excerpt(msg.content || (msg.attachments?.size ? '（添付ファイル）' : ''))
    try { writeStatus(stateDir, { state: 'working', text }) } catch {}
  })

  client.once('ready', () => {
    try { writeStatus(stateDir, { state: 'idle' }) } catch {}
    apply()
  })

  // status.json はフックが別のプロセスから書くので、見回って変わっていたら送る
  setInterval(apply, POLL_MS)

  process.stderr.write('discord status: attached\n')
}
