import { Codex } from '@openai/codex-sdk'
import {
  ActivityType,
  Client,
  Events,
  GatewayIntentBits,
  Partials,
  REST,
  Routes,
  SlashCommandBuilder,
} from 'discord.js'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { basename, dirname, extname, join } from 'node:path'

const stateDir = process.env.DISCORD_STATE_DIR
const projectPath = process.env.CODEX_PROJECT_PATH
const projectName = process.env.CODEX_PROJECT_NAME || basename(projectPath || '') || 'Codex'

if (!stateDir || !projectPath) {
  throw new Error('DISCORD_STATE_DIR and CODEX_PROJECT_PATH are required')
}

const envFile = join(stateDir, '.env')
const accessFile = join(stateDir, 'access.json')
const sessionFile = join(stateDir, 'codex-session.json')
const incomingDir = join(stateDir, 'incoming')

function readBotToken() {
  const line = readFileSync(envFile, 'utf8').split(/\r?\n/).find(v => v.startsWith('DISCORD_BOT_TOKEN='))
  const token = line?.slice('DISCORD_BOT_TOKEN='.length).trim()
  if (!token) throw new Error(`DISCORD_BOT_TOKEN is missing in ${envFile}`)
  return token
}

function readAccess() {
  return JSON.parse(readFileSync(accessFile, 'utf8'))
}

function readThreadId() {
  if (!existsSync(sessionFile)) return null
  try {
    const value = JSON.parse(readFileSync(sessionFile, 'utf8'))
    return typeof value.threadId === 'string' ? value.threadId : null
  } catch {
    return null
  }
}

function saveThreadId(threadId) {
  writeFileSync(sessionFile, `${JSON.stringify({ threadId, updatedAt: new Date().toISOString() }, null, 2)}\n`)
}

function clearThreadId() {
  writeFileSync(sessionFile, `${JSON.stringify({ threadId: null, updatedAt: new Date().toISOString() }, null, 2)}\n`)
}

async function allowed(message) {
  const access = readAccess()
  const userId = message.author.id
  if (message.guildId) {
    const group = access.groups?.[message.channelId]
    if (!group || !group.allowFrom?.includes(userId)) return false
    if (!group.requireMention) return true
    if (message.mentions.has(client.user)) return true
    if (!message.reference?.messageId) return false
    try {
      const replied = await message.fetchReference()
      return replied.author.id === client.user.id
    } catch {
      return false
    }
  }
  return access.dmPolicy === 'allowlist' && access.allowFrom?.includes(userId)
}

function cleanPrompt(message) {
  return message.content
    .replace(new RegExp(`<@!?${client.user.id}>`, 'g'), '')
    .trim()
}

function safeName(name) {
  const cleaned = basename(name).replace(/[^A-Za-z0-9._-]/g, '_')
  return cleaned || `attachment-${Date.now()}`
}

async function downloadAttachments(message) {
  if (!message.attachments.size) return { images: [], files: [] }
  mkdirSync(incomingDir, { recursive: true })
  const images = []
  const files = []
  for (const attachment of message.attachments.values()) {
    const name = `${Date.now()}-${attachment.id}-${safeName(attachment.name || 'file')}`
    const path = join(incomingDir, name)
    const response = await fetch(attachment.url)
    if (!response.ok) throw new Error(`添付ファイルを取得できませんでした (${response.status})`)
    writeFileSync(path, Buffer.from(await response.arrayBuffer()))
    const image = attachment.contentType?.startsWith('image/') || ['.png', '.jpg', '.jpeg', '.webp'].includes(extname(path).toLowerCase())
    if (image) images.push(path)
    else files.push(path)
  }
  return { images, files }
}

function threadOptions() {
  return {
    workingDirectory: projectPath,
    skipGitRepoCheck: true,
    sandboxMode: 'workspace-write',
    approvalPolicy: 'never',
  }
}

// Discord からは確認なしで動かすので、Codex アプリのプラグイン（コンピューター操作・ブラウザ・Slack など）と
// ユーザー設定の MCP サーバーは使わせない。これらはサンドボックスの外で動き、workspace-write では縛れない。
const OFF_FEATURES = [
  'plugins', 'apps', 'remote_plugin', 'computer_use',
  'browser_use', 'browser_use_external', 'in_app_browser', 'skill_mcp_dependency_install',
]

// SDK と同じ、このフォルダの node_modules に入っている codex.exe
function codexBinary() {
  const [pkg, triple] = process.arch === 'arm64'
    ? ['@openai/codex-win32-arm64', 'aarch64-pc-windows-msvc']
    : ['@openai/codex-win32-x64', 'x86_64-pc-windows-msvc']
  const req = createRequire(createRequire(import.meta.url).resolve('@openai/codex/package.json'))
  return join(dirname(req.resolve(`${pkg}/package.json`)), 'vendor', triple, 'bin', 'codex.exe')
}

// プロジェクトごとに使ってよいと決めた MCP サーバー（管理画面か cdiscord mcp で選ぶ。カンマ区切り）
const allowedMcp = new Set((process.env.CODEX_ALLOWED_MCP || '').split(',').map(v => v.trim()).filter(Boolean))

// MCP サーバーは「全部消す」設定がないので、作業フォルダで見えるもののうち、許可していないものを名前で 1 つずつ止める。
// 一覧が取れなければ、止められたか分からないまま動かさないよう起動をやめる。
function lockdownConfig() {
  const features = Object.fromEntries(OFF_FEATURES.map(name => [name, false]))
  const args = OFF_FEATURES.flatMap(name => ['-c', `features.${name}=false`])
  const servers = JSON.parse(execFileSync(codexBinary(), [...args, 'mcp', 'list', '--json'], {
    cwd: projectPath, encoding: 'utf8', windowsHide: true,
  }))
  const off = servers.filter(s => !allowedMcp.has(s.name)).map(s => s.name)
  const on = servers.filter(s => allowedMcp.has(s.name)).map(s => s.name)
  const mcp_servers = Object.fromEntries(off.map(name => [name, { enabled: false }]))
  console.log(`[${projectName}] Codex: plugins off, MCP servers allowed: ${on.join(', ') || 'none'} / off: ${off.join(', ') || 'none'}`)
  return { features, mcp_servers }
}

const codex = new Codex({ config: lockdownConfig() })
let thread = readThreadId() ? codex.resumeThread(readThreadId(), threadOptions()) : codex.startThread(threadOptions())
let busy = false
let queue = Promise.resolve()
let currentStep = ''

function newThread() {
  thread = codex.startThread(threadOptions())
  clearThreadId()
  currentStep = ''
}

function describeItem(item) {
  switch (item.type) {
    case 'command_execution': return `コマンド: ${item.command}`
    case 'file_change': return `ファイル変更: ${item.changes.map(v => basename(v.path)).join(', ')}`
    case 'mcp_tool_call': return `ツール: ${item.server}/${item.tool}`
    case 'web_search': return `検索: ${item.query}`
    default: return ''
  }
}

function setPresence(status, text = '') {
  if (!client.user) return
  const activities = text ? [{ name: text.slice(0, 120), type: ActivityType.Custom }] : []
  client.user.setPresence({ status, activities })
}

async function sendLong(channel, text) {
  const value = (text || '完了しました。').trim()
  for (let start = 0; start < value.length; start += 1900) {
    await channel.send({ content: value.slice(start, start + 1900), allowedMentions: { parse: [] } })
  }
}

async function runPrompt(message) {
  busy = true
  currentStep = '指示を確認中'
  setPresence('dnd', `⏳ ${currentStep}`)
  const typing = setInterval(() => message.channel.sendTyping().catch(() => {}), 8000)
  try {
    await message.channel.sendTyping()
    const prompt = cleanPrompt(message)
    const attachments = await downloadAttachments(message)
    const fileNote = attachments.files.length
      ? `\n\nDiscord の添付ファイルは次に保存されています。必要に応じて読み取ってください:\n${attachments.files.join('\n')}`
      : ''
    const inputs = [{ type: 'text', text: `${prompt || '添付ファイルを確認してください。'}${fileNote}` }]
    for (const path of attachments.images) inputs.push({ type: 'local_image', path })

    let finalResponse = ''
    let retried = false
    while (true) {
      try {
        const { events } = await thread.runStreamed(inputs)
        for await (const event of events) {
          if (event.type === 'thread.started') saveThreadId(event.thread_id)
          if (event.type === 'item.started' || event.type === 'item.updated') {
            const step = describeItem(event.item)
            if (step) {
              currentStep = step
              setPresence('dnd', `⏳ ${step}`)
            }
          }
          if (event.type === 'item.completed' && event.item.type === 'agent_message') {
            finalResponse = event.item.text
          }
          if (event.type === 'turn.failed' || event.type === 'error') {
            throw new Error(event.type === 'error' ? event.message : event.error.message)
          }
        }
        break
      } catch (error) {
        if (retried || !readThreadId()) throw error
        retried = true
        newThread()
      }
    }
    if (thread.id) saveThreadId(thread.id)
    await sendLong(message.channel, finalResponse)
  } catch (error) {
    console.error(error)
    await sendLong(message.channel, `❌ Codex の実行に失敗しました。\n${error instanceof Error ? error.message : String(error)}`)
  } finally {
    clearInterval(typing)
    busy = false
    currentStep = ''
    setPresence('online')
  }
}

const token = readBotToken()
const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.DirectMessages,
    GatewayIntentBits.MessageContent,
  ],
  partials: [Partials.Channel],
})

client.once(Events.ClientReady, async ready => {
  console.log(`[${projectName}] Codex Discord connected as ${ready.user.tag}`)
  setPresence('online')
  const access = readAccess()
  const commands = [
    new SlashCommandBuilder().setName('restart').setDescription('Codex の新しい会話を始めます'),
    new SlashCommandBuilder().setName('resume').setDescription('保存済みの Codex 会話を使い続けます'),
    new SlashCommandBuilder().setName('status').setDescription('Codex の状態を表示します'),
  ].map(v => v.toJSON())
  const guildIds = new Set()
  for (const channelId of Object.keys(access.groups || {})) {
    try {
      const channel = await client.channels.fetch(channelId)
      if (channel?.guildId) guildIds.add(channel.guildId)
    } catch (error) {
      console.error(`Could not fetch channel ${channelId}:`, error)
    }
  }
  const rest = new REST().setToken(token)
  for (const guildId of guildIds) {
    try {
      await rest.put(Routes.applicationGuildCommands(client.user.id, guildId), { body: commands })
    } catch (error) {
      console.error(`Could not register slash commands in guild ${guildId}:`, error)
    }
  }
})

client.on(Events.MessageCreate, async message => {
  if (message.author.bot || !(await allowed(message))) return
  queue = queue.then(() => runPrompt(message))
})

client.on(Events.InteractionCreate, async interaction => {
  if (!interaction.isChatInputCommand()) return
  const access = readAccess()
  const group = interaction.guildId ? access.groups?.[interaction.channelId] : null
  const userAllowed = interaction.guildId
    ? group?.allowFrom?.includes(interaction.user.id)
    : access.allowFrom?.includes(interaction.user.id)
  if (!userAllowed) {
    await interaction.reply({ content: 'このコマンドを使う権限がありません。', ephemeral: true })
    return
  }
  if (busy && interaction.commandName !== 'status') {
    await interaction.reply({ content: 'Codex が作業中です。完了してからもう一度実行してください。', ephemeral: true })
    return
  }
  if (interaction.commandName === 'restart') {
    newThread()
    await interaction.reply('✅ 新しい Codex 会話を始めます。')
  } else if (interaction.commandName === 'resume') {
    const id = readThreadId()
    if (id) thread = codex.resumeThread(id, threadOptions())
    await interaction.reply(id ? '✅ 保存済みの Codex 会話を読み直しました。' : '保存済みの会話はありません。次のメッセージから新しく始めます。')
  } else if (interaction.commandName === 'status') {
    await interaction.reply({
      content: `状態: ${busy ? '作業中' : '待機中'}\n作業: ${currentStep || 'なし'}\n会話 ID: ${readThreadId() || '未作成'}`,
      ephemeral: true,
    })
  }
})

client.on(Events.Error, error => console.error('Discord client error:', error))

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    client.destroy()
    process.exit(0)
  })
}

await client.login(token)
