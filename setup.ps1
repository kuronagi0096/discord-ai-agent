# setup.ps1 — Discord から話せる Claude Code の初回セットアップ（setup.cmd から動く）
#
# することは次の 4 つ。それぞれ実行前に確認する。何度実行しても大丈夫。
#   1. claude / codex、node、bun が使えるか確かめる
#   2. discord プラグインが入っていなければ入れる
#   3. ユーザー設定（~/.claude/settings.json）でプラグインを無効にする
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
if (Get-Command claude -ErrorAction SilentlyContinue) { Write-Host 'claude … OK' }
else {
    Write-Host 'claude が見つかりません（Claude Code を使う場合だけ必要です）。' -ForegroundColor Yellow
}
if (Get-Command codex -ErrorAction SilentlyContinue) { Write-Host 'codex … OK' }
else { Write-Host 'codex が見つかりません（Codex を使う場合は Codex アプリまたは CLI を入れて、先にログインしてください）。' -ForegroundColor Yellow }
if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and -not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Host 'claude または codex のどちらかが必要です。' -ForegroundColor Yellow
    $missing = $true
}
if (Get-Command node -ErrorAction SilentlyContinue) { Write-Host 'node … OK' }
else { Write-Host 'node が見つかりません。Codex SDK には Node.js 18 以上が必要です。' -ForegroundColor Yellow; $missing = $true }
if (Get-Command bun -ErrorAction SilentlyContinue) { Write-Host 'bun … OK' }
else {
    Write-Host 'bun が見つかりません。PowerShell で次を実行して入れてから、新しいウィンドウでやり直してください：' -ForegroundColor Yellow
    Write-Host '  powershell -c "irm bun.sh/install.ps1 | iex"'
    $missing = $true
}
if ($missing) { Read-Host '終了します（Enter）'; exit 1 }

if (-not (Test-Path -LiteralPath (Join-Path $Root 'node_modules\@openai\codex-sdk'))) {
    if (Ask-YesNo 'Codex SDK と Discord クライアントを npm install しますか？') { & npm install --prefix $Root }
    else { Write-Host 'Codex を使う前に、このフォルダで npm install を実行してください。' -ForegroundColor Yellow }
}

# ---------- 2. プラグイン ----------
Step '2. discord プラグイン'
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

# ---------- 3. ユーザー設定でプラグインを無効に ----------
Step '3. ほかの Claude ではプラグインを動かさない'
$status = (& bun (Join-Path $Root 'setup-tools.ts') plugin-status).Trim()
if ($status -like '* disabled') { Write-Host 'ユーザー設定で無効になっています … OK' }
else {
    Write-Host 'ユーザー設定（~/.claude/settings.json）で discord プラグインを無効にします。'
    Write-Host 'Discord 用に起動したセッションでだけ有効になります（バックアップを取ってから書き換えます）。'
    if (Ask-YesNo '無効にしますか？') { & bun (Join-Path $Root 'setup-tools.ts') disable-plugin }
    else { Write-Host 'そのままにします。ボットがオンラインにならないことがあれば、ここをやり直してください。' -ForegroundColor Yellow }
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
