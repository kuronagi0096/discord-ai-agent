// Discord のスラッシュコマンドで、このプロジェクトのセッションを操作する。
//   /restart … ウィンドウを閉じて、新しい会話で起動し直す
//   /resume  … ウィンドウを閉じて、今の会話を引き継いで起動し直す（固まったとき・調子が悪いとき）
//   /status  … 今の状態を自分にだけ見せる
//
// discord プラグインの server.ts に apply-plugin-patch.ts が 1 行足し、attach(client, STATE_DIR) が呼ばれる。
// プラグイン（bun）が動いていれば、Claude が固まっていても受け付けられる。
// 起動し直しは cdiscord.cmd restart <名前> に任せる。それがこのプロセスごとウィンドウを閉じるので、
// 間に cmd の start をはさんで、閉じる側の木（taskkill /T）に入らないようにしている。
// 起動し直したあと、新しいプロセスが ready になったら restart-notice.json を見て「起動しました」とチャンネルに書く。

import { readFileSync, writeFileSync, rmSync, existsSync } from 'fs'
import { join, basename } from 'path'
import { spawn } from 'child_process'
import { readStatus } from './status-presence.ts'

const ROOT = import.meta.dir
const NOTICE_MAX_AGE_MS = 5 * 60 * 1000

const COMMANDS = [
  { name: 'restart', description: 'このプロジェクトの Claude を、新しい会話で起動し直す', type: 1 },
  { name: 'resume', description: 'このプロジェクトの Claude を、今の会話を引き継いで起動し直す（固まったとき）', type: 1 },
  { name: 'status', description: 'このプロジェクトの Claude の今の状態を見る', type: 1 },
]

function loadJson(f: string): any {
  try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return undefined }
}

function ago(ms: number): string {
  const s = Math.round((Date.now() - ms) / 1000)
  if (s < 60) return `${s} 秒前`
  if (s < 3600) return `${Math.round(s / 60)} 分前`
  return `${Math.round(s / 3600)} 時間前`
}

export function attach(client: any, stateDir: string): void {
  const name = basename(stateDir).replace(/^discord-/, '')
  const access = () => loadJson(join(stateDir, 'access.json')) ?? {}
  const sessionId = (): string | undefined => {
    const id = loadJson(join(stateDir, 'session.json'))?.session_id
    return typeof id === 'string' && /^[0-9a-fA-F-]{36}$/.test(id) ? id : undefined
  }

  const restart = (resumeId?: string) => {
    // name は英数字と '-'、resumeId は UUID だけなので、そのまま並べてよい
    const line = `start "" /min powershell -NoProfile -ExecutionPolicy Bypass -File "${join(ROOT, 'claude-discord.ps1')}" restart ${name}` +
      (resumeId ? ` -Resume ${resumeId}` : '')
    const child = spawn('cmd.exe', ['/d', '/c', line], { detached: true, stdio: 'ignore', windowsHide: true, windowsVerbatimArguments: true })
    child.unref()
  }

  client.once('ready', async () => {
    // 登録チャンネルのあるサーバーに、このボットのコマンドを登録する（同じ内容なら Discord 側で何も変わらない）
    const guilds = new Set<string>()
    for (const id of Object.keys(access().groups ?? {})) {
      try { const ch = await client.channels.fetch(id); if (ch?.guildId) guilds.add(ch.guildId) } catch {}
    }
    for (const g of guilds) {
      try { await client.application.commands.set(COMMANDS, g) }
      catch (e) { process.stderr.write(`discord commands: register in ${g} failed: ${e}\n`) }
    }

    // 起動し直したあとのお知らせ
    const f = join(stateDir, 'restart-notice.json')
    const n = loadJson(f)
    if (existsSync(f)) rmSync(f, { force: true })
    if (n?.channelId && Date.now() - (n.at ?? 0) < NOTICE_MAX_AGE_MS) {
      try {
        const ch = await client.channels.fetch(n.channelId)
        await ch.send(n.resume ? '✅ 起動し直しました（会話を引き継ぎ）。' : '✅ 起動し直しました（新しい会話）。')
      } catch (e) { process.stderr.write(`discord commands: notice failed: ${e}\n`) }
    }
  })

  client.on('interactionCreate', async (it: any) => {
    if (!it.isChatInputCommand?.() || !COMMANDS.some(c => c.name === it.commandName)) return
    const a = access()
    if (!(a.allowFrom ?? []).includes(it.user.id)) {
      await it.reply({ content: '使えるのは登録された人だけです。', ephemeral: true }).catch(() => {})
      return
    }
    // 同じサーバーにいるほかのプロジェクトのボットのコマンドを、違うチャンネルで選んでしまったとき
    if (it.channelId && !(it.channelId in (a.groups ?? {})) && it.guildId) {
      await it.reply({ content: `このチャンネルは「${name}」の担当ではありません。コマンドを選ぶときに、このチャンネルのボットのものを選んでください。`, ephemeral: true }).catch(() => {})
      return
    }

    switch (it.commandName) {
      case 'status': {
        const s = readStatus(stateDir)
        const label = s.state === 'working' ? '⏳ 作業中' : s.state === 'waiting' ? '❓ 確認待ち' : '✅ 待機中'
        const lines = [
          `**${name}**：${label}${s.at ? `（${ago(s.at)}に更新）` : ''}`,
          s.step ? `今の一手：${s.step}` : '',
          s.text ? `指示：${s.text}` : '',
          `会話：${sessionId() ?? '（まだありません）'}`,
        ].filter(Boolean)
        await it.reply({ content: lines.join('\n'), ephemeral: true }).catch(() => {})
        return
      }
      case 'restart':
      case 'resume': {
        const resume = it.commandName === 'resume'
        const id = resume ? sessionId() : undefined
        if (resume && !id) {
          await it.reply({ content: '引き継げる会話が見つかりません。/restart で新しく始めてください。', ephemeral: true }).catch(() => {})
          return
        }
        await it.reply(resume ? '🔄 今の会話を引き継いで起動し直します…' : '🔄 新しい会話で起動し直します…').catch(() => {})
        try {
          writeFileSync(join(stateDir, 'restart-notice.json'), JSON.stringify({ channelId: it.channelId, resume, at: Date.now() }))
          restart(id)
        } catch (e) {
          await it.followUp({ content: `起動し直せませんでした：${e}` }).catch(() => {})
        }
        return
      }
    }
  })

  process.stderr.write('discord commands: attached\n')
}
