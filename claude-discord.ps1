# claude-discord.ps1  (v2)
# One Discord bot + one Claude Code or Codex session per project.
# Nothing in this file needs editing. Projects are stored in:
#   claude-discord.json (in the same folder as this script)
#
# Commands:
#   add     : register a project (run it inside the project folder, answers a few prompts)
#   remove  : unregister a project            e.g. remove my-project
#   list    : show registered projects        (default)
#   start   : launch all projects, or one     e.g. start my-project
#   restart : close a project's window and start it again   e.g. restart my-project
#             -Resume <session id> continues that conversation instead of starting a new one
#             (used by the /restart and /resume commands on Discord, see discord-commands.ts)
#   mention : react only to @bot in the channel, or to everything   e.g. mention my-project on
#   agent   : choose claude or codex for a project                  e.g. agent my-project codex
#   setup   : rewrite access.json for all projects, ask for any missing tokens
#
# (Messages are ASCII only on purpose, so the file works in Windows PowerShell 5.1
#  regardless of how it is saved.)

param(
    [Parameter(Position = 0)]
    [ValidateSet('add', 'remove', 'list', 'start', 'restart', 'mention', 'agent', 'setup')]
    [string]$Command = 'list',

    [Parameter(Position = 1)]
    [string]$Name = '',

    [Parameter(Position = 2)]
    [string]$Value = '',

    [string]$Path = '',
    [string]$ChannelId = '',
    [string]$Resume = ''
)

$ErrorActionPreference = 'Stop'
$Plugin     = 'plugin:discord@claude-plugins-official'
$Root       = $PSScriptRoot   # this script's folder (config, tokens and access.json live here)
$ConfigFile = Join-Path $Root 'claude-discord.json'
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

# ---------- helpers ----------

function Test-Snowflake([string]$id) {
    ($id -match '^\d{17,20}$') -and ($id -notmatch '^0+$')
}

function Ask([string]$label, [string]$default = '') {
    $prompt = if ($default) { "$label [$default]" } else { $label }
    $answer = (Read-Host $prompt).Trim()
    if ($answer) { $answer } else { $default }
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

function Confirm-UserId($cfg) {
    if (Test-Snowflake $cfg.userId) { return }
    Write-Host 'First run: your own Discord user ID is needed once.'
    Write-Host '(Discord: right-click your avatar -> Copy User ID)'
    while ($true) {
        $id = Ask 'Your Discord user ID'
        if (Test-Snowflake $id) { break }
        Write-Warning 'That does not look like a Discord ID (17-20 digits).'
    }
    $cfg.userId = $id
    Save-Config $cfg
}

function Find-Project($cfg, [string]$projectName) {
    foreach ($p in $cfg.projects) {
        if ($p.name -eq $projectName) { return $p }
    }
    return $null
}

function Select-Projects($cfg) {
    if ($Name) {
        $p = Find-Project $cfg $Name
        if ($null -eq $p) { throw "No project named '$Name'. Run 'list' to see names." }
        return @($p)
    }
    return @($cfg.projects)
}

# Only you can talk to the bot, only in this project's channel (and by DM).
# With requireMention on, the channel only reacts to @bot (and replies to the bot). The plugin
# re-reads access.json for every message, so the change takes effect at once.
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

# The token file must be a single line, no BOM, no trailing CRLF,
# or the plugin will not read it. Returns $true when a token is in place.
function Save-Token($p) {
    $envFile = Join-Path (Get-StateDir $p.name) '.env'
    if (Test-Path -LiteralPath $envFile) { return $true }

    $sec  = Read-Host -AsSecureString "[$($p.name)] paste the bot token"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try     { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $token = $token.Trim()
    if (-not $token) { return $false }

    [System.IO.File]::WriteAllText($envFile, "DISCORD_BOT_TOKEN=$token", $Utf8NoBom)
    return $true
}

# Other Claude sessions (desktop app etc.) used to try the discord plugin without a token,
# fail, and leave a "recent failure" mark that made channel sessions started within 15 minutes
# skip the plugin. The plugin is now enabled only for channel sessions (channel-settings.json),
# and any leftover mark is cleared before starting.
$ChannelSettings = Join-Path $Root 'channel-settings.json'

function Clear-McpFailure {
    $f = Join-Path $HOME '.claude\mcp-needs-auth-cache.json'
    if (-not (Test-Path -LiteralPath $f)) { return }
    try {
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.PSObject.Properties['plugin:discord:discord']) {
            $j.PSObject.Properties.Remove('plugin:discord:discord')
            [System.IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $j -Compress -Depth 5), $Utf8NoBom)
        }
    }
    catch { Write-Warning "Could not clear the MCP failure mark: $($_.Exception.Message)" }
}

# Before every start: rebuild channel-settings.json for this folder's location, and add the lines that bot status,
# Discord buttons and slash commands need to the discord plugin's server.ts (plugin updates remove them).
# See prepare.ts. Failure never blocks starting.
function Invoke-Prepare {
    try { & bun (Join-Path $Root 'prepare.ts') | Write-Host }
    catch { Write-Warning "Could not prepare: $($_.Exception.Message)" }
}

# Windows started by cdiscord / the GUI carry DISCORD_STATE_DIR inside -EncodedCommand; that is how they are found.
function Get-RunningMap {
    $map = @{}
    foreach ($pr in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
        $cl = [string]$pr.CommandLine
        if ($cl -notmatch '-EncodedCommand\s+(\S+)') { continue }
        try { $text = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) } catch { continue }
        if ($text -match "DISCORD_STATE_DIR = '([^']+)'") {
            $leaf = Split-Path -Leaf $Matches[1]
            if ($leaf -like 'discord-*') { $map[$leaf.Substring(8)] = [int]$pr.ProcessId }
        }
    }
    return $map
}

# The Codex bot runs on node with packages from this folder's node_modules (setup.cmd installs them).
function Test-CodexDeps {
    (Test-Path -LiteralPath (Join-Path $Root 'node_modules\@openai\codex-sdk')) -and
    (Test-Path -LiteralPath (Join-Path $Root 'node_modules\discord.js'))
}

function Start-Project($cfg, $p, [string]$resumeId = '') {
    $dir = Get-StateDir $p.name
    if (-not (Test-Path -LiteralPath (Join-Path $dir '.env'))) {
        Write-Warning "[$($p.name)] no token saved. Run 'setup'."
        return
    }
    if (-not (Test-Path -LiteralPath $p.path)) {
        Write-Warning "[$($p.name)] folder not found: $($p.path)"
        return
    }
    $qDir  = $dir -replace "'", "''"
    $qPath = $p.path -replace "'", "''"
    $agent = if ($p.agent -eq 'codex') { 'codex' } else { 'claude' }
    if ($agent -eq 'codex') {
        if (-not (Test-CodexDeps)) {
            Write-Warning "[$($p.name)] Codex SDK / discord.js are not installed in $Root\node_modules. Run setup.cmd."
            return
        }
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
        Clear-McpFailure
        Invoke-Prepare
        $resumeArg = if ($resumeId -match '^[0-9a-fA-F-]{36}$') { "--resume $resumeId" } else { '' }
        $cmd = @(
            "`$Host.UI.RawUI.WindowTitle = 'claude: $($p.name)'"
            "`$env:DISCORD_STATE_DIR = '$qDir'"
            "Set-Location -LiteralPath '$qPath'"
            "claude --channels $Plugin --settings '$($ChannelSettings -replace "'", "''")' $resumeArg $($cfg.extraArgs)"
        ) -join '; '
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell -ArgumentList @('-NoExit', '-EncodedCommand', $encoded)
    Write-Host "[$($p.name)] started."
}

# ---------- commands ----------

function Invoke-Add {
    $cfg = Read-Config
    Confirm-UserId $cfg

    # Folder: the one you are standing in. Use -Path to register a different one.
    $folder = if ($Path) { $Path } else { (Get-Location).Path }
    $folder = $folder.Trim('"').Trim("'")
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw "Folder not found: $folder"
    }
    $folder = (Resolve-Path -LiteralPath $folder).ProviderPath
    Write-Host "Project folder: $folder"

    # Name: defaults to the folder name, cleaned up.
    $suggested = ((Split-Path -Leaf $folder).ToLower() -replace '[^a-z0-9-]+', '-').Trim('-')
    if (-not $suggested) { $suggested = 'project' }
    $projectName = if ($Name) { $Name } else { Ask 'Name' $suggested }
    if ($projectName -notmatch '^[A-Za-z0-9-]+$') {
        throw "Name may only contain letters, digits and '-': $projectName"
    }
    if (Find-Project $cfg $projectName) {
        throw "A project named '$projectName' already exists. Use 'remove' first, or pick another name."
    }

    # Channel ID.
    $channel = $ChannelId
    while (-not (Test-Snowflake $channel)) {
        if ($channel) { Write-Warning 'That does not look like a channel ID (17-20 digits).' }
        $channel = Ask 'Discord channel ID (right-click channel -> Copy Channel ID)'
    }
    foreach ($other in $cfg.projects) {
        if ($other.channelId -eq $channel) {
            throw "Channel $channel is already used by '$($other.name)'."
        }
    }

    $agent = Ask 'Agent (claude/codex)' 'codex'
    if ($agent -notin @('claude', 'codex')) { throw "Agent must be 'claude' or 'codex'." }
    $p = [ordered]@{ name = $projectName; path = $folder; channelId = $channel; requireMention = $false; agent = $agent }
    Write-Access $cfg $p
    if (-not (Save-Token $p)) {
        Write-Warning 'No token entered. Nothing was registered.'
        return
    }

    [void]$cfg.projects.Add($p)
    Save-Config $cfg
    Write-Host ''
    Write-Host "Added '$projectName' -> $folder"

    $go = Ask 'Start it now? (y/n)' 'y'
    if ($go -match '^[Yy]') { Start-Project $cfg $p }
}

function Invoke-Remove {
    if (-not $Name) { throw "Usage: remove <name>" }
    $cfg = Read-Config
    $p = Find-Project $cfg $Name
    if ($null -eq $p) { throw "No project named '$Name'." }

    $keep = New-Object System.Collections.ArrayList
    foreach ($x in $cfg.projects) {
        if ($x.name -ne $Name) { [void]$keep.Add($x) }
    }
    $cfg.projects = $keep
    Save-Config $cfg
    Write-Host "Removed '$Name' from the list."

    $dir = Get-StateDir $Name
    if (Test-Path -LiteralPath $dir) {
        $del = Ask "Also delete its saved token and settings folder? (y/n)" 'n'
        if ($del -match '^[Yy]') {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Host "Deleted $dir"
        }
        else {
            Write-Host "Kept $dir"
        }
    }
    Write-Host 'If its window is still open, close it to stop the bot.'
}

function Invoke-List {
    $cfg = Read-Config
    if ($cfg.projects.Count -eq 0) {
        Write-Host "No projects yet. Go to a project folder and run: add"
        return
    }
    Write-Host "User ID: $($cfg.userId)"
    foreach ($p in $cfg.projects) {
        $hasToken = Test-Path -LiteralPath (Join-Path (Get-StateDir $p.name) '.env')
        Write-Host ''
        Write-Host "[$($p.name)]"
        Write-Host "  folder  : $($p.path)"
        Write-Host "  agent   : $($p.agent)"
        Write-Host "  channel : $($p.channelId)"
        Write-Host "  reacts  : $(if ($p.requireMention) { 'only to @bot (mention on)' } else { 'to every message (mention off)' })"
        Write-Host "  token   : $(if ($hasToken) { 'saved' } else { 'missing (run setup)' })"
    }
}

function Invoke-Start {
    $cfg = Read-Config
    $targets = Select-Projects $cfg
    if ($targets.Count -eq 0) {
        Write-Host "No projects yet. Go to a project folder and run: add"
        return
    }
    foreach ($p in $targets) { Start-Project $cfg $p }
}

function Invoke-Restart {
    if (-not $Name) { throw 'Usage: restart <name> [-Resume <session id>]' }
    $cfg = Read-Config
    $p = Find-Project $cfg $Name
    if ($null -eq $p) { throw "No project named '$Name'." }
    # Give the Discord command a moment to post its reply before the bot goes away.
    Start-Sleep -Seconds 3
    $running = Get-RunningMap
    if ($running.ContainsKey($p.name)) {
        & taskkill.exe /PID $running[$p.name] /T /F | Out-Null
        Write-Host "[$($p.name)] stopped."
        Start-Sleep -Seconds 2
    }
    Start-Project $cfg $p $Resume
}

function Invoke-Mention {
    if (-not $Name -or $Value -notin @('on', 'off')) { throw 'Usage: mention <name> on|off' }
    $cfg = Read-Config
    $p = Find-Project $cfg $Name
    if ($null -eq $p) { throw "No project named '$Name'." }
    $p.requireMention = ($Value -eq 'on')
    Save-Config $cfg
    Write-Access $cfg $p
    Write-Host "[$($p.name)] $(if ($p.requireMention) { 'reacts only to @bot (and replies to the bot)' } else { 'reacts to every message' }) in its channel. Takes effect now."
}

function Invoke-Agent {
    if (-not $Name -or $Value -notin @('claude', 'codex')) { throw 'Usage: agent <name> claude|codex' }
    $cfg = Read-Config
    $p = Find-Project $cfg $Name
    if ($null -eq $p) { throw "No project named '$Name'." }
    $p.agent = $Value
    Save-Config $cfg
    Write-Host "[$($p.name)] agent is now $Value. Restart it if it is running."
}

function Invoke-Setup {
    $cfg = Read-Config
    Confirm-UserId $cfg
    foreach ($p in (Select-Projects $cfg)) {
        Write-Access $cfg $p
        if (Save-Token $p) { Write-Host "[$($p.name)] ok." }
        else               { Write-Warning "[$($p.name)] no token entered." }
    }
}

switch ($Command) {
    'add'    { Invoke-Add }
    'remove' { Invoke-Remove }
    'list'   { Invoke-List }
    'start'  { Invoke-Start }
    'restart' { Invoke-Restart }
    'mention' { Invoke-Mention }
    'agent'   { Invoke-Agent }
    'setup'  { Invoke-Setup }
}
