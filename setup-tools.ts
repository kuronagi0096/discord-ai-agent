// setup.ps1 から呼ばれる小さな道具。JSON の書き換えは PowerShell 5.1 だと形が崩れやすいので bun でやる。
//
//   bun setup-tools.ts disable-plugin   … ~/.claude/settings.json で discord プラグインを無効にする（Discord 用のセッションでだけ有効にするため）
//   bun setup-tools.ts plugin-status    … プラグインが入っているか（installed / missing）と、ユーザー設定での有効・無効を表示

import { readFileSync, writeFileSync, copyFileSync, existsSync } from 'fs'
import { join } from 'path'
import { homedir } from 'os'

const PLUGIN = 'discord@claude-plugins-official'
const SETTINGS = join(homedir(), '.claude', 'settings.json')

function readSettings(): any {
  if (!existsSync(SETTINGS)) return {}
  return JSON.parse(readFileSync(SETTINGS, 'utf8'))
}

switch (process.argv[2]) {
  case 'plugin-status': {
    // Cache files can remain after uninstall, so ask Claude Code for the actual installed-plugin registry.
    const result = Bun.spawnSync(['claude', 'plugin', 'list', '--json'], { stdout: 'pipe', stderr: 'pipe' })
    let installed = false
    if (result.exitCode === 0) {
      try {
        const plugins = JSON.parse(result.stdout.toString())
        installed = JSON.stringify(plugins).includes(PLUGIN)
      } catch { }
    }
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
