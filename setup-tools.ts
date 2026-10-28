// setup.ps1 から呼ばれる小さな道具。JSON の書き換えは PowerShell 5.1 だと形が崩れやすいので bun でやる。
//
//   bun setup-tools.ts disable-plugin   … ~/.claude/settings.json で discord プラグインを無効にする（Discord 用のセッションでだけ有効にするため）
//   bun setup-tools.ts plugin-status    … プラグインが入っているか（installed / missing）と、ユーザー設定での有効・無効を表示

import { readFileSync, writeFileSync, copyFileSync, existsSync, readdirSync } from 'fs'
import { join } from 'path'
import { homedir } from 'os'

const PLUGIN = 'discord@claude-plugins-official'
const SETTINGS = join(homedir(), '.claude', 'settings.json')
const PLUGIN_DIR = join(homedir(), '.claude', 'plugins', 'cache', 'claude-plugins-official', 'discord')

function readSettings(): any {
  if (!existsSync(SETTINGS)) return {}
  return JSON.parse(readFileSync(SETTINGS, 'utf8'))
}

switch (process.argv[2]) {
  case 'plugin-status': {
    const installed = existsSync(PLUGIN_DIR) && readdirSync(PLUGIN_DIR).some(v => existsSync(join(PLUGIN_DIR, v, 'server.ts')))
    const enabled = readSettings().enabledPlugins?.[PLUGIN]
    console.log(`${installed ? 'installed' : 'missing'} ${enabled === undefined ? 'unset' : enabled ? 'enabled' : 'disabled'}`)
    break
  }
  case 'disable-plugin': {
    const s = readSettings()
    if (s.enabledPlugins?.[PLUGIN] === false) { console.log('already disabled'); break }
    if (existsSync(SETTINGS)) {
      const backup = `${SETTINGS}.bak-${new Date().toISOString().replace(/[:.]/g, '-')}`
      copyFileSync(SETTINGS, backup)
      console.log(`backup: ${backup}`)
    }
    s.enabledPlugins = { ...(s.enabledPlugins ?? {}), [PLUGIN]: false }
    writeFileSync(SETTINGS, JSON.stringify(s, null, 2) + '\n')
    console.log('disabled')
    break
  }
  default:
    console.error('usage: bun setup-tools.ts plugin-status | disable-plugin')
    process.exit(1)
}
