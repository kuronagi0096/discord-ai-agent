# claude-discord-gui.ps1
# Discord から話せる Claude Code / Codex のプロジェクトを、画面で追加・編集・削除・起動・停止する。
# 設定の形は claude-discord.ps1 と同じ（このスクリプトと同じフォルダの claude-discord.json と discord-<名前>\access.json / .env）。
# Windows PowerShell 5.1 で日本語が化けないよう、このファイルは UTF-8（BOM 付き）で保存する。
param([switch]$NoShow)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$Plugin      = 'plugin:discord@claude-plugins-official'
$Root        = $PSScriptRoot   # このスクリプトのあるフォルダ
$ConfigFile  = Join-Path $Root 'claude-discord.json'
$CliCmd      = Join-Path $Root 'cdiscord.cmd'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Discord 起動.lnk'
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

# ---------- 設定（claude-discord.ps1 と同じ形） ----------

function Test-Snowflake([string]$id) {
    ($id -match '^\d{17,20}$') -and ($id -notmatch '^0+$')
}

function Get-StateDir([string]$projectName) {
    Join-Path $Root ('discord-' + $projectName)
}

function Read-Config {
    $cfg = [ordered]@{
        userId    = ''
        extraArgs = ''
        projects  = New-Object System.Collections.ArrayList
    }
    if (Test-Path -LiteralPath $ConfigFile) {
        $raw = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($raw.userId)    { $cfg.userId    = [string]$raw.userId }
        if ($raw.extraArgs) { $cfg.extraArgs = [string]$raw.extraArgs }
        foreach ($x in @($raw.projects)) {
            if ($null -eq $x) { continue }
            [void]$cfg.projects.Add([ordered]@{
                name      = [string]$x.name
                path      = [string]$x.path
                channelId = [string]$x.channelId
                requireMention = [bool]$x.requireMention
                agent     = if ($x.agent -eq 'codex') { 'codex' } else { 'claude' }
            })
        }
    }
    return $cfg
}

function Save-Config($cfg) {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $json = ConvertTo-Json -InputObject $cfg -Depth 5
    [System.IO.File]::WriteAllText($ConfigFile, $json, $Utf8NoBom)
}

function Find-Project($cfg, [string]$projectName) {
    foreach ($p in $cfg.projects) {
        if ($p.name -eq $projectName) { return $p }
    }
    return $null
}

# 話しかけられるのは自分だけ（そのプロジェクトのチャンネルと DM）
# requireMention がオンなら、チャンネルでは @ボット したとき（とボットへの返信）だけ反応する。プラグインは毎回読み直すので、すぐ効く
function Write-Access($cfg, $p) {
    $dir = Get-StateDir $p.name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $groups = @{}
    $groups[[string]$p.channelId] = [ordered]@{
        requireMention = [bool]$p.requireMention
        allowFrom      = @($cfg.userId)
    }
    $access = [ordered]@{
        dmPolicy  = 'allowlist'
        allowFrom = @($cfg.userId)
        groups    = $groups
        pending   = @{}
    }
    $json = ConvertTo-Json -InputObject $access -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $dir 'access.json'), $json, $Utf8NoBom)
}

# トークンのファイルは 1 行・BOM なし・改行なし（そうでないとプラグインが読めない）
function Save-Token($p, [string]$token) {
    $dir = Get-StateDir $p.name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir '.env'), "DISCORD_BOT_TOKEN=$($token.Trim())", $Utf8NoBom)
}

function Test-Token($p) {
    Test-Path -LiteralPath (Join-Path (Get-StateDir $p.name) '.env')
}

# ---------- 起動・停止 ----------

# 起動中のプロジェクト（名前 → PowerShell のプロセス ID）。
# cdiscord / この画面が起動したウィンドウは -EncodedCommand の中に DISCORD_STATE_DIR を持つので、それで見分ける
function Get-RunningMap {
    $map = @{}
    foreach ($pr in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
        $cl = [string]$pr.CommandLine
        if ($cl -notmatch '-EncodedCommand\s+(\S+)') { continue }
        $b64 = $Matches[1]
        try { $text = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64)) } catch { continue }
        if ($text -match "DISCORD_STATE_DIR = '([^']+)'") {
            $leaf = Split-Path -Leaf $Matches[1]
            if ($leaf -like 'discord-*') { $map[$leaf.Substring(8)] = [int]$pr.ProcessId }
        }
    }
    return $map
}

# ほかの Claude（デスクトップアプリなど）が discord プラグインをトークンなしで起動して失敗すると、
# 「最近失敗した」印が残り、15 分以内に起動したチャンネル用のセッションがプラグインを飛ばしてしまう。
# プラグインはチャンネル用のセッションだけで有効にし（channel-settings.json）、起動前に印も消す
$ChannelSettings = Join-Path $Root 'channel-settings.json'

function Clear-McpFailure {
    $f = Join-Path $HOME '.claude\mcp-needs-auth-cache.json'
    if (-not (Test-Path -LiteralPath $f)) { return }
    $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.PSObject.Properties['plugin:discord:discord']) {
        $j.PSObject.Properties.Remove('plugin:discord:discord')
        [System.IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $j -Compress -Depth 5), $Utf8NoBom)
    }
}

# 起動の前に、channel-settings.json をこのフォルダの場所に合わせて作り直し、ステータス・ボタン・コマンドのための行を
# discord プラグインの server.ts に足す（prepare.ts。失敗しても起動は止めない）
function Invoke-Prepare {
    try { & bun (Join-Path $Root 'prepare.ts') | Out-Null } catch { }
}

function Start-Project($cfg, $p) {
    $dir = Get-StateDir $p.name
    if (-not (Test-Token $p)) { throw "[$($p.name)] ボットのトークンがありません。「編集」で入れてください。" }
    if (-not (Test-Path -LiteralPath $p.path)) { throw "[$($p.name)] フォルダが見つかりません：$($p.path)" }
    $qDir  = $dir -replace "'", "''"
    $qPath = $p.path -replace "'", "''"
    $agent = if ($p.agent -eq 'codex') { 'codex' } else { 'claude' }
    if ($agent -eq 'codex') {
        $runner = (Join-Path $Root 'codex-discord.mjs') -replace "'", "''"
        $qName = ([string]$p.name) -replace "'", "''"
        $cmd = @(
            "`$Host.UI.RawUI.WindowTitle = 'codex: $qName'"
            "`$env:DISCORD_STATE_DIR = '$qDir'"
            "`$env:CODEX_PROJECT_PATH = '$qPath'"
            "`$env:CODEX_PROJECT_NAME = '$qName'"
            "Set-Location -LiteralPath '$qPath'"
            "node '$runner'"
        ) -join '; '
    }
    else {
        try { Clear-McpFailure } catch { }
        Invoke-Prepare
        $cmd = @(
            "`$Host.UI.RawUI.WindowTitle = 'claude: $($p.name)'"
            "`$env:DISCORD_STATE_DIR = '$qDir'"
            "Set-Location -LiteralPath '$qPath'"
            "claude --channels $Plugin --settings '$($ChannelSettings -replace "'", "''")' $($cfg.extraArgs)"
        ) -join '; '
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell -ArgumentList @('-NoExit', '-EncodedCommand', $encoded)
}

function Stop-Project([int]$processId) {
    # ウィンドウの中の claude ごと止める
    & taskkill.exe /PID $processId /T /F | Out-Null
}

# ---------- ログイン時の自動起動 ----------

function Test-Startup { Test-Path -LiteralPath $StartupLink }

function Set-Startup([bool]$on) {
    if (-not $on) {
        if (Test-Startup) { Remove-Item -LiteralPath $StartupLink }
        return
    }
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($StartupLink)
    $lnk.TargetPath = $env:ComSpec
    # ログイン直後はネットワークがまだつながっていないことがあるので、20 秒待ってから起動する
    $lnk.Arguments = '/c "timeout /t 20 /nobreak >nul & "' + $CliCmd + '" start"'
    $lnk.WorkingDirectory = $Root
    $lnk.WindowStyle = 7
    $lnk.Description = 'ログイン時に Discord から話せる Claude Code を起動する（cdiscord start）'
    $lnk.Save()
}

if ($NoShow) { return }

# ---------- 画面 ----------

$font = New-Object System.Drawing.Font('Yu Gothic UI', 9.5)

function Show-Message([string]$text, [string]$icon = 'Information', [string]$buttons = 'OK') {
    [System.Windows.Forms.MessageBox]::Show($text, 'Claude Discord', $buttons, $icon)
}

function New-Label($text, $x, $y, $w = 120) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 22)
    $l.TextAlign = 'MiddleLeft'
    return $l
}

function New-TextBox($x, $y, $w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, 24)
    return $t
}

function New-Button($text, $x, $y, $w = 120) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 30)
    return $b
}

# 追加・編集のダイアログ。OK なら @{ path; name; channelId; token; requireMention; agent } を返す（編集でトークンが空なら今のまま）
function Show-ProjectDialog($cfg, $existing) {
    $editing = $null -ne $existing
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($editing) { "編集：$($existing.name)" } else { 'プロジェクトを追加' }
    $dlg.Font = $font
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 336)

    $dlg.Controls.Add((New-Label '作業フォルダ' 16 18))
    $tPath = New-TextBox 140 18 310
    $bBrowse = New-Button '参照…' 458 15 86
    $dlg.Controls.Add((New-Label '名前' 16 58))
    $tName = New-TextBox 140 58 200
    $dlg.Controls.Add((New-Label '英数字と - だけ' 350 58 190))
    $dlg.Controls.Add((New-Label 'チャンネル ID' 16 98))
    $tChannel = New-TextBox 140 98 200
    $dlg.Controls.Add((New-Label '右クリック → ID をコピー' 350 98 200))
    $dlg.Controls.Add((New-Label 'ボットのトークン' 16 138))
    $tToken = New-TextBox 140 138 404
    $tToken.UseSystemPasswordChar = $true
    $hint = New-Label '' 140 166 404
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $hint.Text = if ($editing) { '空のままなら、今のトークンを使います' } else { 'Discord Developer Portal の Bot → Reset Token で出る文字列' }
    $dlg.Controls.Add((New-Label 'エージェント' 16 196))
    $cAgent = New-Object System.Windows.Forms.ComboBox
    $cAgent.DropDownStyle = 'DropDownList'
    $cAgent.Location = New-Object System.Drawing.Point(140, 194); $cAgent.Size = New-Object System.Drawing.Size(200, 24)
    [void]$cAgent.Items.Add('Codex')
    [void]$cAgent.Items.Add('Claude Code')
    $cAgent.SelectedIndex = 0
    $cMention = New-Object System.Windows.Forms.CheckBox
    $cMention.Text = 'チャンネルでは @ボット したとき（とボットへの返信）だけ反応する'
    $cMention.Location = New-Object System.Drawing.Point(140, 232); $cMention.Size = New-Object System.Drawing.Size(404, 24)
    $ok = New-Button 'OK' 330 288 100
    $cancel = New-Button 'キャンセル' 444 288 100
    $dlg.Controls.AddRange(@($tPath, $bBrowse, $tName, $tChannel, $tToken, $hint, $cAgent, $cMention, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    if ($editing) {
        $tPath.Text = $existing.path; $tName.Text = $existing.name; $tName.Enabled = $false; $tChannel.Text = $existing.channelId
        $cMention.Checked = [bool]$existing.requireMention
        $cAgent.SelectedIndex = if ($existing.agent -eq 'codex') { 0 } else { 1 }
    }

    $bBrowse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Claude に作業させるフォルダ'
        if ($tPath.Text -and (Test-Path -LiteralPath $tPath.Text)) { $fb.SelectedPath = $tPath.Text }
        if ($fb.ShowDialog($dlg) -eq 'OK') {
            $tPath.Text = $fb.SelectedPath
            if (-not $tName.Text -and $tName.Enabled) {
                $tName.Text = ((Split-Path -Leaf $fb.SelectedPath).ToLower() -replace '[^a-z0-9-]+', '-').Trim('-')
            }
        }
    })

    $script:dialogResult = $null
    $ok.Add_Click({
        $path = $tPath.Text.Trim().Trim('"')
        $name = $tName.Text.Trim()
        $channel = $tChannel.Text.Trim()
        $token = $tToken.Text.Trim()
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { Show-Message '作業フォルダが見つかりません。' 'Warning'; return }
        if ($name -notmatch '^[A-Za-z0-9-]+$') { Show-Message '名前は英数字と - だけにしてください。' 'Warning'; return }
        if (-not $editing -and (Find-Project $cfg $name)) { Show-Message "「$name」はもう登録されています。" 'Warning'; return }
        if (-not (Test-Snowflake $channel)) { Show-Message 'チャンネル ID は 17〜20 桁の数字です。' 'Warning'; return }
        foreach ($other in $cfg.projects) {
            if ($other.channelId -eq $channel -and $other.name -ne $name) { Show-Message "このチャンネルは「$($other.name)」で使っています。" 'Warning'; return }
        }
        if (-not $editing -and -not $token) { Show-Message 'ボットのトークンを入れてください。' 'Warning'; return }
        $agent = if ($cAgent.SelectedIndex -eq 0) { 'codex' } else { 'claude' }
        $script:dialogResult = @{ path = (Resolve-Path -LiteralPath $path).ProviderPath; name = $name; channelId = $channel; token = $token; requireMention = $cMention.Checked; agent = $agent }
        $dlg.DialogResult = 'OK'
        $dlg.Close()
    })

    [void]$dlg.ShowDialog($form)
    return $script:dialogResult
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Discord の管理'
$form.Font = $font
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(900, 470)
$form.MinimumSize = New-Object System.Drawing.Size(760, 420)

$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false
$list.Location = New-Object System.Drawing.Point(12, 12)
$list.Size = New-Object System.Drawing.Size(730, 360)
$list.Anchor = 'Top, Bottom, Left, Right'
[void]$list.Columns.Add('名前', 130)
[void]$list.Columns.Add('状態', 70)
[void]$list.Columns.Add('Agent', 80)
[void]$list.Columns.Add('作業フォルダ', 240)
[void]$list.Columns.Add('チャンネル ID', 150)
[void]$list.Columns.Add('トークン', 70)
[void]$list.Columns.Add('反応', 80)
$form.Controls.Add($list)

$buttons = @{}
$y = 12
foreach ($b in @(@('add', '追加…'), @('edit', '編集…'), @('remove', '削除…'), @('-', ''), @('start', '起動'), @('stop', '停止'), @('startAll', 'すべて起動'), @('-', ''), @('open', 'フォルダを開く'))) {
    if ($b[0] -eq '-') { $y += 12; continue }
    $btn = New-Button $b[1] 756 $y 132
    $btn.Anchor = 'Top, Right'
    $form.Controls.Add($btn)
    $buttons[$b[0]] = $btn
    $y += 38
}

$lUser = New-Label 'あなたの Discord ユーザー ID' 12 388 190
$lUser.Anchor = 'Bottom, Left'
$tUser = New-TextBox 204 388 200
$tUser.Anchor = 'Bottom, Left'
$bUser = New-Button '保存' 412 385 70
$bUser.Anchor = 'Bottom, Left'
$cStartup = New-Object System.Windows.Forms.CheckBox
$cStartup.Text = 'ログイン時に自動で起動する'
$cStartup.Location = New-Object System.Drawing.Point(12, 426); $cStartup.Size = New-Object System.Drawing.Size(260, 24)
$cStartup.Anchor = 'Bottom, Left'
$status = New-Label '' 290 426 600
$status.Anchor = 'Bottom, Left, Right'
$status.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.AddRange(@($lUser, $tUser, $bUser, $cStartup, $status))

$script:cfg = Read-Config
$tUser.Text = $script:cfg.userId
$cStartup.Checked = Test-Startup

function Get-Selected {
    if ($list.SelectedItems.Count -eq 0) { return $null }
    return Find-Project $script:cfg ([string]$list.SelectedItems[0].Tag)
}

function Update-Buttons {
    $p = Get-Selected
    $running = $p -and $script:running.ContainsKey($p.name)
    $buttons['edit'].Enabled = [bool]$p
    $buttons['remove'].Enabled = [bool]$p
    $buttons['open'].Enabled = [bool]$p
    $buttons['start'].Enabled = $p -and -not $running
    $buttons['stop'].Enabled = [bool]$running
}

function Update-List {
    $selected = if ($list.SelectedItems.Count) { [string]$list.SelectedItems[0].Tag } else { '' }
    $script:running = Get-RunningMap
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($p in $script:cfg.projects) {
        $item = New-Object System.Windows.Forms.ListViewItem($p.name)
        $item.Tag = $p.name
        $isRunning = $script:running.ContainsKey($p.name)
        [void]$item.SubItems.Add($(if ($isRunning) { '起動中' } else { '停止' }))
        [void]$item.SubItems.Add($(if ($p.agent -eq 'codex') { 'Codex' } else { 'Claude' }))
        [void]$item.SubItems.Add($p.path)
        [void]$item.SubItems.Add($p.channelId)
        [void]$item.SubItems.Add($(if (Test-Token $p) { 'あり' } else { 'なし' }))
        [void]$item.SubItems.Add($(if ($p.requireMention) { '@ のみ' } else { 'すべて' }))
        if ($isRunning) { $item.ForeColor = [System.Drawing.Color]::ForestGreen }
        [void]$list.Items.Add($item)
        if ($p.name -eq $selected) { $item.Selected = $true }
    }
    $list.EndUpdate()
    $count = $script:running.Count
    $status.Text = "登録 $($script:cfg.projects.Count) 件・起動中 $count 件　（設定：$ConfigFile）"
    Update-Buttons
}

function Confirm-UserId {
    if (Test-Snowflake $script:cfg.userId) { return $true }
    Show-Message '先に、下の欄にあなたの Discord ユーザー ID（アイコンを右クリック → ユーザー ID をコピー）を入れて「保存」してください。' 'Warning'
    $tUser.Focus()
    return $false
}

function Invoke-Safely([scriptblock]$action) {
    try { & $action } catch { Show-Message $_.Exception.Message 'Error' }
    Update-List
}

$list.Add_SelectedIndexChanged({ Update-Buttons })
$list.Add_DoubleClick({ $buttons['edit'].PerformClick() })

$buttons['add'].Add_Click({ Invoke-Safely {
    if (-not (Confirm-UserId)) { return }
    $r = Show-ProjectDialog $script:cfg $null
    if (-not $r) { return }
    $p = [ordered]@{ name = $r.name; path = $r.path; channelId = $r.channelId; requireMention = $r.requireMention; agent = $r.agent }
    Write-Access $script:cfg $p
    Save-Token $p $r.token
    [void]$script:cfg.projects.Add($p)
    Save-Config $script:cfg
    if ((Show-Message "「$($p.name)」を追加しました。今すぐ起動しますか？" 'Question' 'YesNo') -eq 'Yes') { Start-Project $script:cfg $p }
} })

$buttons['edit'].Add_Click({ Invoke-Safely {
    $p = Get-Selected
    if (-not $p) { return }
    $r = Show-ProjectDialog $script:cfg $p
    if (-not $r) { return }
    $needsRestart = ($p.path -ne $r.path) -or ($p.channelId -ne $r.channelId) -or ($p.agent -ne $r.agent) -or [bool]$r.token
    $p.path = $r.path
    $p.channelId = $r.channelId
    $p.requireMention = $r.requireMention
    $p.agent = $r.agent
    Write-Access $script:cfg $p
    if ($r.token) { Save-Token $p $r.token }
    Save-Config $script:cfg
    if ($needsRestart -and $script:running.ContainsKey($p.name)) { Show-Message '起動中のウィンドウには、停止して起動し直すと反映されます。' }
} })

$buttons['remove'].Add_Click({ Invoke-Safely {
    $p = Get-Selected
    if (-not $p) { return }
    if ((Show-Message "「$($p.name)」を一覧から削除しますか？" 'Question' 'YesNo') -ne 'Yes') { return }
    if ($script:running.ContainsKey($p.name)) { Stop-Project $script:running[$p.name] }
    $keep = New-Object System.Collections.ArrayList
    foreach ($x in $script:cfg.projects) { if ($x.name -ne $p.name) { [void]$keep.Add($x) } }
    $script:cfg.projects = $keep
    Save-Config $script:cfg
    $dir = Get-StateDir $p.name
    if ((Test-Path -LiteralPath $dir) -and (Show-Message "保存してあるトークンと設定のフォルダも削除しますか？`n$dir" 'Question' 'YesNo') -eq 'Yes') {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
} })

$buttons['start'].Add_Click({ Invoke-Safely {
    $p = Get-Selected
    if ($p -and (Confirm-UserId)) { Start-Project $script:cfg $p; Start-Sleep -Milliseconds 800 }
} })

$buttons['stop'].Add_Click({ Invoke-Safely {
    $p = Get-Selected
    if (-not $p -or -not $script:running.ContainsKey($p.name)) { return }
    if ((Show-Message "「$($p.name)」のウィンドウを閉じて止めますか？（Claude の作業中なら中断されます）" 'Question' 'YesNo') -eq 'Yes') { Stop-Project $script:running[$p.name] }
} })

$buttons['startAll'].Add_Click({ Invoke-Safely {
    if (-not (Confirm-UserId)) { return }
    $errors = @()
    foreach ($p in $script:cfg.projects) {
        if ($script:running.ContainsKey($p.name)) { continue }
        try { Start-Project $script:cfg $p } catch { $errors += $_.Exception.Message }
    }
    if ($errors) { Show-Message ($errors -join "`n") 'Warning' }
    Start-Sleep -Milliseconds 800
} })

$buttons['open'].Add_Click({ Invoke-Safely {
    $p = Get-Selected
    if ($p) { Start-Process explorer.exe -ArgumentList "`"$($p.path)`"" }
} })

$bUser.Add_Click({ Invoke-Safely {
    $id = $tUser.Text.Trim()
    if (-not (Test-Snowflake $id)) { Show-Message 'ユーザー ID は 17〜20 桁の数字です。' 'Warning'; return }
    $script:cfg.userId = $id
    Save-Config $script:cfg
    # 話しかけられる人の設定を、全プロジェクトで書き直す
    foreach ($p in $script:cfg.projects) { Write-Access $script:cfg $p }
    Show-Message '保存しました。起動中のウィンドウには、起動し直すと反映されます。'
} })

$cStartup.Add_CheckedChanged({
    try { Set-Startup $cStartup.Checked } catch { Show-Message $_.Exception.Message 'Error' }
})

# 起動中かどうかを数秒ごとに見直す（ウィンドウを手で閉じたときなど）
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({ try { Update-List } catch { } })
$form.Add_Shown({ Update-List; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop() })

[void]$form.ShowDialog()
