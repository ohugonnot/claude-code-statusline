# install.ps1 - Claude Code Status Line installer for native Windows
#
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main/install.ps1 | iex
#
# With a custom refresh interval (seconds):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main/install.ps1))) -Refresh 120
#
# What it does:
#   1. Makes sure Git for Windows (Git Bash + curl) and jq are installed (via winget)
#   2. Downloads statusline.sh to %USERPROFILE%\.claude\hooks\
#   3. Sets "statusLine" in %USERPROFILE%\.claude\settings.json (existing file is backed up)
param(
    [ValidateRange(1, 86400)]
    [int]$Refresh = 0
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$RepoRaw     = 'https://raw.githubusercontent.com/ohugonnot/claude-code-statusline/main'
$UserHome    = $env:USERPROFILE
$HooksDir    = Join-Path $UserHome '.claude\hooks'
$ScriptPath  = Join-Path $HooksDir 'statusline.sh'
$SettingsFile = Join-Path $UserHome '.claude\settings.json'

function Write-Step($msg) { Write-Host ""; Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [ok] $msg" -ForegroundColor Green }

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Find-GitBash {
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    # Fall back to locating git.exe and deriving bash.exe from it
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $root = Split-Path (Split-Path $git.Source -Parent) -Parent
        $b = Join-Path $root 'bin\bash.exe'
        if (Test-Path $b) { return $b }
    }
    return $null
}

function Install-WithWinget($id, $label) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is not available. Install $label manually, then re-run this script."
    }
    Write-Host "  Installing $label with winget..."
    winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
    # winget exits non-zero when already installed / nothing to do; verified by the caller afterwards
    Refresh-Path
}

Write-Host "=== Claude Code Status Line Installer (Windows) ===" -ForegroundColor Cyan

# 1. Dependencies -------------------------------------------------------------
Write-Step "Checking dependencies..."
Refresh-Path   # pick up tools installed since this terminal was opened

$bash = Find-GitBash
if (-not $bash) {
    Install-WithWinget 'Git.Git' 'Git for Windows'
    $bash = Find-GitBash
    if (-not $bash) { throw "Git Bash not found after install. Install Git for Windows from https://git-scm.com and re-run." }
}
Write-Ok "Git Bash: $bash"

if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    Install-WithWinget 'jqlang.jq' 'jq'
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        throw "jq not found after install. Install it (winget install jqlang.jq) and re-run."
    }
}
Write-Ok "jq: $((Get-Command jq).Source)"

# curl ships with Git for Windows (Git Bash) - nothing more to install
Write-Ok "curl: provided by Git for Windows"

# 2. statusline.sh ------------------------------------------------------------
Write-Step "Installing statusline.sh..."
New-Item -ItemType Directory -Force -Path $HooksDir | Out-Null

$content = (Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/statusline.sh").Content
if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
$content = $content -replace "`r`n", "`n"   # bash needs LF line endings

if ($Refresh -gt 0) {
    $content = $content -replace 'REFRESH_INTERVAL="\$\{REFRESH_INTERVAL:-\d+\}"', "REFRESH_INTERVAL=`"`${REFRESH_INTERVAL:-$Refresh}`""
    Write-Ok "Refresh interval set to ${Refresh}s"
}

[IO.File]::WriteAllText($ScriptPath, $content, (New-Object Text.UTF8Encoding($false)))
Write-Ok "Installed: $ScriptPath"

# 3. settings.json ------------------------------------------------------------
Write-Step "Configuring Claude Code..."
New-Item -ItemType Directory -Force -Path (Split-Path $SettingsFile) | Out-Null

# Absolute forward-slash paths work from cmd, PowerShell and Git Bash alike.
$bashFwd   = $bash -replace '\\', '/'
$scriptFwd = $ScriptPath -replace '\\', '/'
$command   = "`"$bashFwd`" `"$scriptFwd`""

$settings = [ordered]@{}
if (Test-Path $SettingsFile) {
    $raw = Get-Content $SettingsFile -Raw
    if ($raw.Trim()) {
        try { $obj = $raw | ConvertFrom-Json } catch { throw "settings.json is not valid JSON - fix it manually, statusLine not configured." }
        foreach ($p in $obj.PSObject.Properties) { $settings[$p.Name] = $p.Value }
    }
    Copy-Item $SettingsFile "$SettingsFile.bak" -Force
    Write-Ok "Backup: $SettingsFile.bak"
}
$settings['statusLine'] = [ordered]@{ type = 'command'; command = $command }

$json = $settings | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($SettingsFile, $json, (New-Object Text.UTF8Encoding($false)))
Write-Ok "statusLine set in $SettingsFile"

# 4. Smoke test ---------------------------------------------------------------
Write-Step "Testing..."
$sample = '{"model":{"display_name":"Sonnet"},"context_window":{"used_percentage":42}}'
$out = $sample | & $bash $scriptFwd 2>&1
if ($LASTEXITCODE -eq 0 -and $out) { Write-Host "  $out" } else { Write-Warning "Test render failed: $out" }

Write-Host ""
Write-Host "Done! Restart Claude Code (and open a NEW terminal) to see the status line." -ForegroundColor Green
