// discord プラグインの server.ts に、このフォルダのモジュールを読み込む行を足す。
//   - status-presence.ts … ボットのステータス（client を作った直後）
//   - discord-commands.ts … /restart /resume /status（client を作った直後）
//   - discord-buttons.ts … 許可の確認をチャンネルに出す・ask_choice（mcp.connect の直前）
// プラグインが更新されると消えるので、cdiscord start / 管理画面の起動のたびに呼ばれる（入っていれば何もしない）。
// 足す場所が見つからない（プラグインの作りが変わった）ものは足さない。その機能が出ないだけで、ボットはふつうに動く。
//
//   bun apply-plugin-patch.ts            … 足す
//   bun apply-plugin-patch.ts --remove   … 外す（元の server.ts に戻る）

import { readFileSync, writeFileSync, readdirSync, existsSync } from 'fs'
import { join } from 'path'
import { homedir } from 'os'

const PLUGIN_DIR = join(homedir(), '.claude', 'plugins', 'cache', 'claude-plugins-official', 'discord')
// 目印の行と、その次の 1 行（読み込み）が足した分
const PATCHED = /\/\/ \[DiscordClaude [^\]\n]*\][^\n]*\n[^\n]*\n/g

const dir = import.meta.dir.replace(/\\/g, '/')
const load = (name: string, file: string, call: string) =>
  `// [DiscordClaude ${name}] ${dir}/${file}\n` +
  `try { (await import(${JSON.stringify(`${dir}/${file}`)})).attach(${call}) } catch (e) { process.stderr.write(\`discord ${name}: patch failed: \${e}\\n\`) }\n`

const PATCHES = [
  {
    name: 'status',
    // const client = new Client({ ... }) の閉じかっこの直後
    anchor: /(\n\s*partials: \[Partials\.Channel\],\r?\n\}\)\r?\n)/,
    insert: (m: string) => m + load('status', 'status-presence.ts', 'client, STATE_DIR'),
  },
  {
    name: 'commands',
    anchor: /(\n\s*partials: \[Partials\.Channel\],\r?\n\}\)\r?\n)/,
    insert: (m: string) => m + load('commands', 'discord-commands.ts', 'client, STATE_DIR'),
  },
  {
    name: 'buttons',
    // ハンドラーを登録し終えて、Claude Code とつなぐ直前
    anchor: /(\nawait mcp\.connect\(new StdioServerTransport\(\)\)\r?\n)/,
    insert: (m: string) => '\n' + load('buttons', 'discord-buttons.ts', 'mcp, client, STATE_DIR, fetchAllowedChannel') + m.slice(1),
  },
]

const remove = process.argv.includes('--remove')
if (!existsSync(PLUGIN_DIR)) { console.log('plugin patch: plugin not found, skipped'); process.exit(0) }

for (const ver of readdirSync(PLUGIN_DIR)) {
  const f = join(PLUGIN_DIR, ver, 'server.ts')
  if (!existsSync(f)) continue
  const src = readFileSync(f, 'utf8')
  let out = src.replace(PATCHED, '')
  const done: string[] = []
  if (!remove) {
    for (const p of PATCHES) {
      if (p.anchor.test(out)) { out = out.replace(p.anchor, p.insert); done.push(p.name) }
      else console.log(`plugin patch: ${ver}: place for '${p.name}' not found, skipped (bot still works without it)`)
    }
  }
  if (out === src) { console.log(`plugin patch: ${ver}: ${remove ? 'not patched' : 'already patched'}`); continue }
  writeFileSync(f, out)
  console.log(`plugin patch: ${ver}: ${remove ? 'removed' : 'applied ' + done.join(', ')}`)
}
