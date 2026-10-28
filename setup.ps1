# setup.ps1 — Discord から話せる Claude Code の初回セットアップ（setup.cmd から動く）
#
# することは次の 4 つ。それぞれ実行前に確認する。何度実行しても大丈夫。
#   1. node、bun、claude（使う人だけ）、Codex 用の部品を確かめ、なければ公式の方法で入れる
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

function Has([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# インストーラーが書き換えた PATH を、このウィンドウにも読み込む（新しいウィンドウを開かずに続けるため）
function Update-Path {
    $env:Path = (@([Environment]::GetEnvironmentVariable('Path', 'Machine'),
                   [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }) -join ';'
}

# 公式のインストール用スクリプトを別の PowerShell で動かす
function Invoke-Installer([string]$script) {
    & powershell -NoProfile -ExecutionPolicy Bypass -Command "irm $script | iex"
    Update-Path
}

function Stop-Setup([string]$message) {
    Write-Host $message -ForegroundColor Red
    Read-Host '終了します（Enter）'; exit 1
}

Write-Host 'Discord から話せる Claude Code / Codex — セットアップ'
Write-Host "フォルダ：$Root"

# ---------- 1. claude / codex と実行環境 ----------
Step '1. 必要なもの'

if (Has node) { Write-Host 'Node.js … OK' }
else {
    Write-Host 'Node.js が入っていません（Codex と Discord のボットに必要です）。' -ForegroundColor Yellow
    if (-not (Has winget)) { Stop-Setup 'winget がないので自動で入れられません。https://nodejs.org から LTS 版を入れてから、もう一度 setup.cmd を実行してください。' }
    if (-not (Ask-YesNo 'いま入れますか？（winget で Node.js LTS を入れます）')) { Stop-Setup 'Node.js を入れてから、もう一度 setup.cmd を実行してください。' }
    & winget install --id OpenJS.NodeJS.LTS -e --source winget
    Update-Path
    if (-not (Has node)) { Stop-Setup 'Node.js を入れられませんでした。上のエラーを確かめるか、https://nodejs.org から入れてください。' }
    Write-Host 'Node.js … OK'
}

if (Has bun) { Write-Host 'bun … OK' }
else {
    Write-Host 'bun が入っていません（このフォルダのスクリプトを動かすのに必要です）。' -ForegroundColor Yellow
    if (-not (Ask-YesNo 'いま入れますか？（公式のインストーラー bun.sh/install.ps1 を使います）')) { Stop-Setup 'bun を入れてから、もう一度 setup.cmd を実行してください。' }
    Invoke-Installer 'bun.sh/install.ps1'
    if (-not (Has bun)) {
        $bunDir = Join-Path $env:USERPROFILE '.bun\bin'
        if (Test-Path -LiteralPath (Join-Path $bunDir 'bun.exe')) { $env:Path = "$env:Path;$bunDir" }
    }
    if (-not (Has bun)) { Stop-Setup 'bun を入れられませんでした。上のエラーを確かめてから、もう一度 setup.cmd を実行してください。' }
    Write-Host 'bun … OK'
}

# claude は Claude Code を使う人だけ必要。公式インストーラーは ~/.local/bin に入れるが、PATH に足されないことがある
$claudeDir = Join-Path $env:USERPROFILE '.local\bin'
function Add-ClaudePath {
    if ((Has claude) -or -not (Test-Path -LiteralPath (Join-Path $claudeDir 'claude.exe'))) { return }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    [Environment]::SetEnvironmentVariable('Path', (@($userPath, $claudeDir) | Where-Object { $_ }) -join ';', 'User')
    $env:Path = "$env:Path;$claudeDir"
    Write-Host "claude の場所（$claudeDir）を PATH に足しました。"
}
$claudeInstalled = $false
if (-not (Has claude) -and (Test-Path -LiteralPath (Join-Path $claudeDir 'claude.exe'))) {
    Write-Host "claude は $claudeDir に入っていますが、PATH（コマンドを探す場所）に入っていません。" -ForegroundColor Yellow
    if (Ask-YesNo 'PATH に足しますか？（このユーザーだけ）') { Add-ClaudePath }
}
if (Has claude) { Write-Host 'Claude Code（claude コマンド）… OK' }
else {
    Write-Host 'Claude Code（claude コマンド）が入っていません。Codex だけ使うなら不要です。' -ForegroundColor Yellow
    Write-Host '  Claude のデスクトップアプリを入れただけでは、このコマンドは入りません。'
    if (Ask-YesNo 'Claude Code も使いますか？（y で公式のインストーラー claude.ai/install.ps1 を使って入れます）') {
        Invoke-Installer 'https://claude.ai/install.ps1'
        Add-ClaudePath
        if (Has claude) { Write-Host 'Claude Code … OK'; $claudeInstalled = $true }
        else { Write-Host '入れられませんでした。2・3 番は飛ばします。上のエラーを確かめてから、もう一度 setup.cmd を実行してください。' -ForegroundColor Yellow }
    }
    else { Write-Host 'Codex だけで進めます（2・3 番は飛ばします）。' }
}
$hasClaude = Has claude

$codexSdk = (Test-Path -LiteralPath (Join-Path $Root 'node_modules\@openai\codex-sdk')) -and
            (Test-Path -LiteralPath (Join-Path $Root 'node_modules\discord.js'))
if ($codexSdk) { Write-Host 'Codex SDK と discord.js（このフォルダの node_modules）… OK' }
else { Write-Host 'Codex SDK と discord.js（このフォルダの node_modules）… 未インストール' -ForegroundColor Yellow }

if (-not $codexSdk) {
    if (Ask-YesNo 'Codex SDK と discord.js をこのフォルダの node_modules に入れますか？（PC 全体には入りません）') {
        # npm.ps1 は「& npm ...」の形で呼ぶと引数を読み違える（Unknown command: "pm"）ので npm.cmd を呼ぶ
        & npm.cmd ci --prefix $Root --no-audit --no-fund
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $Root 'node_modules\@openai\codex-sdk'))) {
            Stop-Setup 'npm ci に失敗しました。上のエラーを確かめてから、もう一度 setup.cmd を実行してください。'
        }
        Write-Host 'Codex SDK と discord.js … OK'
        $codexSdk = $true
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
        # 入れたばかりの claude は公式マーケットプレイスの一覧が古い（または未登録）で、discord が見つからないことがある
        Write-Host '公式マーケットプレイスの一覧を最新にしています…'
        & claude plugin marketplace update claude-plugins-official
        if ($LASTEXITCODE -ne 0) { & claude plugin marketplace add anthropics/claude-plugins-official }
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

# ---------- ログイン ----------
# ログインはブラウザで本人がするしかないので、必要なときに案内だけする
Step 'ログイン'
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
if (Test-Path -LiteralPath (Join-Path $codexHome 'auth.json')) { Write-Host 'Codex（ChatGPT）… ログイン済み' }
elseif ($codexSdk) {
    Write-Host 'Codex（ChatGPT）にまだログインしていません（Codex を使う場合だけ必要です）。' -ForegroundColor Yellow
    if (Ask-YesNo 'いまログインしますか？（ブラウザが開きます）') { & (Join-Path $Root 'node_modules\.bin\codex.cmd') login }
    else { Write-Host 'あとで Codex アプリでログインするか、setup.cmd をもう一度実行してください。' }
}
if ($claudeInstalled) {
    Write-Host 'Claude Code は入れたばかりなので、ログインが必要です。' -ForegroundColor Yellow
    Write-Host '  新しい PowerShell で claude を一度起動して、ブラウザでログインしてください（終わったら /exit で閉じます）。'
}
elseif ($hasClaude) { Write-Host 'Claude Code … 入っています（まだログインしていなければ、claude を一度起動してログインしてください）' }

# ---------- おわり ----------
& bun (Join-Path $Root 'prepare.ts') | Out-Null
Step 'できました'
Write-Host '次は、プロジェクトごとにボットを用意して登録します（README の「ボットを作る」）。'
Write-Host '登録は「Claude Discord 管理」の「追加…」か、プロジェクトのフォルダで cdiscord add。'
Write-Host 'ログイン時に自動で起動したいときは、管理画面の「ログイン時に自動で起動する」をオンにします。'
Read-Host '閉じます（Enter）'
