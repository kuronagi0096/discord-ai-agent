# setup.ps1 — Discord から話せる Claude Code の初回セットアップ（setup.cmd から動く）
#
# することは次の 4 つ。それぞれ実行前に確認する。何度実行しても大丈夫。
#   1. claude / codex、node、bun が使えるか確かめる
#   2. discord プラグインが入っていなければ入れる
#   3. ユーザー設定（~/.claude/settings.json）でプラグインを無効にする（画面では「ふだんの Claude と Discord 用の Claude を分ける」）
#      … Discord 用ではない Claude（デスクトップアプリなど）がトークンなしでプラグインを動かして失敗し、
#        その「失敗の印」で Discord 用のセッションまでプラグインを飛ばす問題を防ぐ。
#        Discord 用のセッションでは、起動時に channel-settings.json で有効にする。
#   4. デスクトップにショートカット（起動・管理）を作る
# このファイルは UTF-8 BOM 付きで保存すること（PowerShell 5.1 で日本語が化けないように）。

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

function Ask-YesNo([string]$question) {
    $a = (Read-Host "$question (y/n)").Trim()
    return $a -match '^[Yy]'
}

function Step([string]$title) {
    Write-Host ''
    Write-Host "== $title ==" -ForegroundColor Cyan
}

Write-Host 'Discord から話せる Claude Code / Codex — セットアップ'
Write-Host "フォルダ：$Root"

# ---------- 1. claude / codex と実行環境 ----------
Step '1. 必要なもの'
$missing = $false
$hasClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue)
if ($hasClaude) { Write-Host 'claude … OK' }
else {
    Write-Host 'claude が見つかりません（Claude Code を使う場合だけ必要です）。2・3 番は飛ばします。' -ForegroundColor Yellow
}
$codexCommand = Get-Command codex -ErrorAction SilentlyContinue
$codexSdk = (Test-Path -LiteralPath (Join-Path $Root 'node_modules\@openai\codex-sdk')) -and
            (Test-Path -LiteralPath (Join-Path $Root 'node_modules\discord.js'))
if ($codexCommand) { Write-Host 'codex CLI … OK' }
if ($codexSdk) { Write-Host 'Codex SDK と discord.js（このフォルダの node_modules）… OK' }
else { Write-Host 'Codex SDK と discord.js（このフォルダの node_modules）… 未インストール（このあと入れるか聞きます）' -ForegroundColor Yellow }
if (Get-Command node -ErrorAction SilentlyContinue) { Write-Host 'Node.js 本体 … OK' }
else { Write-Host 'node が見つかりません。Codex SDK には Node.js 18 以上が必要です。' -ForegroundColor Yellow; $missing = $true }
if (Get-Command bun -ErrorAction SilentlyContinue) { Write-Host 'bun … OK' }
else {
    Write-Host 'bun が見つかりません。PowerShell で次を実行して入れてから、新しいウィンドウでやり直してください：' -ForegroundColor Yellow
    Write-Host '  powershell -c "irm bun.sh/install.ps1 | iex"'
    $missing = $true
}
if ($missing) { Read-Host '終了します（Enter）'; exit 1 }

if (-not $codexSdk) {
    if (Ask-YesNo 'Codex SDK と discord.js をこのフォルダの node_modules に入れますか？（PC 全体には入りません）') {
        # npm.ps1 は「& npm ...」の形で呼ぶと引数を読み違える（Unknown command: "pm"）ので npm.cmd を呼ぶ
        & npm.cmd ci --prefix $Root --no-audit --no-fund
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $Root 'node_modules\@openai\codex-sdk'))) {
            Write-Host 'npm ci に失敗しました。上のエラーを確かめてから、もう一度 setup.cmd を実行してください。' -ForegroundColor Red
            Read-Host '終了します（Enter）'; exit 1
        }
        Write-Host 'Codex SDK と discord.js … OK'
    }
    else { Write-Host 'Codex を使う前に、もう一度 setup.cmd を実行して入れてください。' -ForegroundColor Yellow }
}

# ---------- 2. プラグイン ----------
Step '2. discord プラグイン'
if (-not $hasClaude) {
    Write-Host 'claude がないので飛ばします（Codex だけ使うなら不要です）。'
    Write-Host 'あとで Claude Code を使うときは、Claude Code を入れてから setup.cmd をもう一度実行してください。'
}
else {
$status = (& bun (Join-Path $Root 'setup-tools.ts') plugin-status).Trim()
if ($status -like 'installed*') { Write-Host 'インストール済み … OK' }
else {
    Write-Host 'discord プラグイン（discord@claude-plugins-official）が入っていません。'
    if (Ask-YesNo 'いま入れますか？') {
        & claude plugin install discord@claude-plugins-official
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'インストールに失敗しました。claude を起動して /plugin から discord を入れてから、もう一度 setup してください。' -ForegroundColor Yellow
            Read-Host '終了します（Enter）'; exit 1
        }
    }
    else { Write-Host '入れずに進みます（あとで入れてください）。' -ForegroundColor Yellow }
}
}

# ---------- 3. ユーザー設定でプラグインを無効に ----------
Step '3. ふだんの Claude と Discord 用の Claude を分ける'
if (-not $hasClaude) { Write-Host 'claude がないので飛ばします。' }
else {
$status =(& bun (Join-Path $Root 'setup-tools.ts') plugin-status).Trim()
if ($status -like '* disabled') { Write-Host 'Discord とつなぐ部品は、Discord 用の Claude でだけ動く設定です … OK' }
else {
    Write-Host 'Discord とつなぐ部品を、Discord 用の Claude でだけ動くようにします。'
    Write-Host 'ふだんの Claude の使い勝手は変わりません。'
    Write-Host ''
    Write-Host '次に当てはまる人だけ n を選んでください。それ以外は y で大丈夫です。'
    Write-Host ''
    Write-Host '  ・ふだんの Claude で discord プラグインを直接使っている'
    Write-Host '      このしくみを使わずに、公式のやり方で Discord とつないでいる人。'
    Write-Host '      y にすると、そちらが動かなくなります。'
    Write-Host ''
    Write-Host '  ・設定ファイルを自分で管理している'
    Write-Host '      会社の管理などで、settings.json を勝手に書き換えてほしくない人。'
    Write-Host ''
    if (Ask-YesNo 'この設定にしますか？（おすすめ：y）') {
        $out = & bun (Join-Path $Root 'setup-tools.ts') disable-plugin
        $backup = $out | Where-Object { $_ -like 'backup: *' } | ForEach-Object { $_.Substring(8) }
        Write-Host '設定しました。'
        if ($backup) { Write-Host "元の設定のコピー：$backup" }
    }
    else { Write-Host 'そのままにします。あとでボットがオンラインにならないときは、setup.cmd をもう一度実行して、ここで y を選んでください。' -ForegroundColor Yellow }
}
}

# ---------- 4. ショートカット ----------
Step '4. デスクトップのショートカット'
if (Ask-YesNo '「Claude Discord 起動」「Claude Discord 管理」を作りますか？') {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $ws = New-Object -ComObject WScript.Shell

    $l = $ws.CreateShortcut((Join-Path $desktop 'Claude Discord 起動.lnk'))
    $l.TargetPath = $env:ComSpec
    $l.Arguments = '/c ""' + (Join-Path $Root 'cdiscord.cmd') + '" start"'
    $l.WorkingDirectory = $Root
    $l.Description = '登録したプロジェクトのボットを全部起動する（cdiscord start）'
    $l.Save()

    $l = $ws.CreateShortcut((Join-Path $desktop 'Claude Discord 管理.lnk'))
    $l.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $l.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $Root 'claude-discord-gui.ps1') + '"'
    $l.WorkingDirectory = $Root
    $l.Description = 'プロジェクトの追加・編集・起動・停止'
    $l.Save()
    Write-Host '作りました。'
}

# ---------- おわり ----------
& bun (Join-Path $Root 'prepare.ts') | Out-Null
Step 'できました'
Write-Host '次は、プロジェクトごとにボットを用意して登録します（README の「ボットを作る」）。'
Write-Host '登録は「Claude Discord 管理」の「追加…」か、プロジェクトのフォルダで cdiscord add。'
Write-Host 'ログイン時に自動で起動したいときは、管理画面の「ログイン時に自動で起動する」をオンにします。'
Read-Host '閉じます（Enter）'
