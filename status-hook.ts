// Claude Code のフックから呼ばれ、<DISCORD_STATE_DIR>\status.json に作業の状態を書く。
// それを status-presence.ts（プラグインの中で動く）が拾って、ボットのステータスに出す。
// フックは channel-settings.json に書いてあるので、Discord 用のセッションでだけ動く。
//
//   bun status-hook.ts prompt  … 指示を受けた（UserPromptSubmit）→ 作業中＋指示の頭
//   bun status-hook.ts pre     … 道具を使う直前（PreToolUse）→ 今の一手（「📝 編集：server.ts」など）
//   bun status-hook.ts notify  … 確認待ち（Notification: permission_prompt）
//   bun status-hook.ts tool    … 道具を使い終えた（PostToolUse）→ 許可の確認待ちだったら作業中に戻す
//   bun status-hook.ts stop    … 返事が終わった（Stop）→ 待機中。ただし ask_choice の答え待ちは残す
//   bun status-hook.ts reset   … セッションの始まりと終わり → 待機中
//
// どのフックでも、セッション ID を <DISCORD_STATE_DIR>\session.json に残す（Discord の /resume が使う）。
// 何があっても標準出力には何も書かない（UserPromptSubmit の出力は Claude への入力に混ざる）。終了コードは常に 0。

import { readFileSync, writeFileSync } from 'fs'
import { join, basename } from 'path'
import { excerpt, writeStatus } from './status-presence.ts'

const stateDir = process.env.DISCORD_STATE_DIR
if (!stateDir) process.exit(0)

const event = process.argv[2]

function readInput(): any {
  try { return JSON.parse(readFileSync(0, 'utf8')) } catch { return {} }
}

function current(): any {
  try { return JSON.parse(readFileSync(join(stateDir!, 'status.json'), 'utf8')) } catch { return { state: 'idle' } }
}

// 道具の名前と中身から、吹き出しに出す「今の一手」を作る
export function describeStep(tool: string, input: any): string | undefined {
  const file = (p: unknown) => (typeof p === 'string' && p ? basename(p.replace(/\\/g, '/')) : '')
  const short = (s: unknown, n: number) => excerpt(String(s ?? '').split(/\r?\n/)[0], n)
  if (/^mcp__.*discord.*__(reply|edit_message|react)$/.test(tool)) return '💬 返信中'
  if (/^mcp__.*discord.*__ask_choice$/.test(tool)) return undefined   // discord-buttons.ts が確認待ちにする
  if (/^mcp__.*discord.*__/.test(tool)) return '💬 Discord を確認中'
  switch (tool) {
    case 'Read': return `📖 読む：${file(input?.file_path)}`
    case 'Edit': case 'MultiEdit': case 'Write': return `📝 編集：${file(input?.file_path)}`
    case 'NotebookEdit': return `📝 編集：${file(input?.notebook_path)}`
    case 'Bash': case 'PowerShell': return `▶ 実行：${short(input?.command, 30)}`
    case 'Grep': case 'Glob': return `🔍 検索：${short(input?.pattern, 20)}`
    case 'WebFetch': case 'WebSearch': return '🌐 調べもの'
    case 'Agent': case 'Task': return '🤖 手分けして作業'
    case 'TodoWrite': case 'TaskCreate': case 'TaskUpdate': return '🗒 段取りを整理'
  }
  return `🔧 ${tool.replace(/^mcp__.*__/, '')}`
}

if (import.meta.main) {
  try {
    const input = readInput()
    if (typeof input.session_id === 'string' && input.session_id) {
      writeFileSync(join(stateDir, 'session.json'), JSON.stringify({ session_id: input.session_id, cwd: input.cwd, at: Date.now() }))
    }
    switch (event) {
      case 'prompt': {
        // Discord から届いた指示は <channel source="discord" ...>本文</channel> の形で来る
        const prompt: string = input.prompt ?? ''
        const m = prompt.match(/<channel\b[^>]*>([\s\S]*?)<\/channel>/)
        const text = excerpt(m ? m[1] : prompt)
        // 許可の返事（yes abcde）や中身のないものでは、受け取ったときの本文を残す
        writeStatus(stateDir, { state: 'working', text: text || current().text })
        break
      }
      case 'pre': {
        const s = current()
        if (s.ask) break
        const step = describeStep(String(input.tool_name ?? ''), input.tool_input)
        if (step) writeStatus(stateDir, { state: 'working', text: s.text, step })
        break
      }
      case 'notify': {
        const s = current()
        writeStatus(stateDir, { state: 'waiting', text: s.text, step: s.step })
        break
      }
      case 'tool': {
        const s = current()
        if (s.state === 'waiting' && !s.ask) writeStatus(stateDir, { state: 'working', text: s.text, step: s.step })
        break
      }
      case 'stop':
        if (current().ask) break
        writeStatus(stateDir, { state: 'idle' })
        break
      case 'reset':
        writeStatus(stateDir, { state: 'idle' })
        break
    }
  } catch {}
  process.exit(0)
}
