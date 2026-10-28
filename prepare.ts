// 起動の直前に呼ばれる準備（cdiscord start / restart、管理画面の起動）。
//   1. channel-settings.json を、このフォルダの場所に合わせて作り直す
//      （プラグインを Discord 用のセッションでだけ有効にする設定と、ステータス表示のフック）
//   2. discord プラグインの server.ts に、このフォルダのモジュールを読み込む行を足す（apply-plugin-patch.ts）
// どちらも、何度実行しても同じ結果になる。

import { writeFileSync } from 'fs'
import { join } from 'path'

const dir = import.meta.dir.replace(/\\/g, '/')
const hook = (event: string, timeout = 10) => ({ type: 'command', command: `bun "${dir}/status-hook.ts" ${event}`, timeout })

const settings = {
  enabledPlugins: { 'discord@claude-plugins-official': true },
  // 選択式の質問はターミナルにしか出ないので、Discord のボタン（ask_choice）を使わせる
  permissions: { deny: ['AskUserQuestion'] },
  hooks: {
    SessionStart: [{ hooks: [hook('reset')] }],
    UserPromptSubmit: [{ hooks: [hook('prompt')] }],
    PreToolUse: [{ matcher: '*', hooks: [hook('pre')] }],
    Notification: [{ matcher: 'permission_prompt', hooks: [hook('notify')] }],
    PostToolUse: [{ matcher: '*', hooks: [hook('tool')] }],
    Stop: [{ hooks: [hook('stop')] }],
    SessionEnd: [{ hooks: [hook('reset')] }],
  },
}

writeFileSync(join(import.meta.dir, 'channel-settings.json'), JSON.stringify(settings, null, 2) + '\n')

await import('./apply-plugin-patch.ts')
