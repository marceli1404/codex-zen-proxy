# =============================================================================
# Codex <-> OpenCode Zen bridge - one-command setup
#
# Installs the Responses-API translation proxy into ~/.codex, generates a
# config.toml that points Codex at it, saves your Zen API key, and starts the
# proxy. Works both from a cloned repo and when piped directly from GitHub:
#
#   git clone https://github.com/marceli1404/codex-zen-proxy && cd codex-zen-proxy
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#
#   # or the fully single-line form:
#   powershell -Command "irm https://raw.githubusercontent.com/marceli1404/codex-zen-proxy/main/setup.ps1 | iex"
#
# Options:
#   -ApiKey   <key>   OpenCode Zen API key (skips the interactive key section)
#   -Model    <slug>  Default model, e.g. mimo-v2.5-free, big-pickle
#                     (skips the interactive model picker)
#   -Port     <int>   Proxy listen port (default 4001)
#   -NoStart          Install/configure only, do not launch the proxy
# =============================================================================

[CmdletBinding()]
param(
    [string]$ApiKey = "",
    [string]$Model = "",
    [int]$Port = 4001,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
function Write-Banner {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor DarkCyan
    Write-Host "     Codex   <->   OpenCode Zen" -ForegroundColor Cyan
    Write-Host "     one-command bridge installer" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}
function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("  --- " + $Title + " " + ("-" * [Math]::Max(1, 58 - $Title.Length))) -ForegroundColor Cyan
}
function Write-OK   { param([string]$m) Write-Host ("   [OK]  " + $m) -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host ("   [!]   " + $m) -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host ("   [ERR] " + $m) -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host ("   [..]  " + $m) -ForegroundColor Gray }

function Test-Interactive {
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Read-MaskedInput {
    param([string]$PromptText)
    $ss = Read-Host -Prompt $PromptText -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-KeyPreview {
    param([string]$k)
    if ($k.Length -le 10) { return "sk-****" }
    return $k.Substring(0, 6) + "..." + $k.Substring($k.Length - 4)
}

# -----------------------------------------------------------------------------
# Start
# -----------------------------------------------------------------------------
Write-Banner

$Interactive = Test-Interactive
$GithubRepo = "https://raw.githubusercontent.com/marceli1404/codex-zen-proxy/main"
$CompanionFiles = @("responses-proxy.js", "start-proxy.ps1", "model-catalog.json")
$AuthUrl = "https://opencode.ai/auth"
$FreeModels = @(
    @{ Slug = "mimo-v2.5-free";        Name = "Mimo 2.5 (free) - balanced all-rounder" },
    @{ Slug = "big-pickle";            Name = "big-pickle (free) - general purpose" },
    @{ Slug = "deepseek-v4-flash-free";Name = "DeepSeek V4 Flash (free) - fast" },
    @{ Slug = "ling-3.0-flash-free";   Name = "Ling 3.0 Flash (free)" },
    @{ Slug = "nemotron-3-ultra-free"; Name = "Nemotron 3 Ultra (free)" },
    @{ Slug = "north-mini-code-free";  Name = "North Mini Code (free) - coding focused" },
    @{ Slug = "laguna-s-2.1-free";     Name = "Laguna S 2.1 (free)" }
)

# --- [1/8] Resolve Codex home + bridge files ---------------------------------
Write-Section "Bridge files"
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null

$SrcDir = $PSScriptRoot
$NeedsFetch = [string]::IsNullOrEmpty($SrcDir) -or -not (Test-Path (Join-Path $SrcDir "responses-proxy.js"))
if ($NeedsFetch) {
    $SrcDir = Join-Path $env:TEMP "codex-zen-proxy"
    New-Item -ItemType Directory -Force -Path $SrcDir | Out-Null
    Write-Info "Downloading bridge files from GitHub..."
    foreach ($f in $CompanionFiles) {
        Invoke-WebRequest "$GithubRepo/$f" -OutFile (Join-Path $SrcDir $f)
    }
}
foreach ($f in $CompanionFiles) {
    Copy-Item (Join-Path $SrcDir $f) (Join-Path $CodexHome $f) -Force
}
Write-OK "Bridge files installed to $CodexHome"

# --- [2/8] Check Node.js -------------------------------------------------------
Write-Section "Prerequisites"
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Err "Node.js is required but was not found."
    Write-Warn "Install it from https://nodejs.org then re-run this script."
    exit 1
}
Write-OK ("Node.js " + (& $node.Source --version))

# --- [3/8] OpenCode Zen API key ------------------------------------------------
Write-Section "OpenCode Zen API key"

$Key = $ApiKey
if ([string]::IsNullOrEmpty($Key)) {
    $Key = [System.Environment]::GetEnvironmentVariable("OPENCODE_ZEN_API_KEY", "User")
}

if (-not [string]::IsNullOrEmpty($Key)) {
    Write-OK ("Found a saved API key: " + (Get-KeyPreview $Key))
    if ($Interactive -and $ApiKey -eq "") {
        $Change = Read-Host "Use this key? [Y/n]"
        if ($Change -match '^[nN]') { $Key = "" }
    }
}

if ([string]::IsNullOrEmpty($Key)) {
    if (-not $Interactive) {
        Write-Err "No OPENCODE_ZEN_API_KEY found and the shell is non-interactive."
        Write-Warn "Get a key at $AuthUrl, then re-run with: -ApiKey sk-xxxx"
        exit 1
    }
    Write-Host ""
    Write-Host "   Don't have an API key yet? It takes about 2 minutes:" -ForegroundColor White
    Write-Host "     1. Open $AuthUrl in your browser" -ForegroundColor Gray
    Write-Host "     2. Sign in with GitHub or Google" -ForegroundColor Gray
    Write-Host "     3. Add billing details (pay-as-you-go, no subscription)" -ForegroundColor Gray
    Write-Host "     4. Go to API keys and click 'Create API key'" -ForegroundColor Gray
    Write-Host "     5. Copy the key (starts with 'sk-') and paste it below" -ForegroundColor Gray
    Write-Host ""
    $Open = Read-Host "Open the key page in your browser now? [Y/n]"
    if ($Open -match '^[yY]' -or $Open -eq "") {
        try { Start-Process $AuthUrl; Write-Info "Opened $AuthUrl - log in and copy your key." }
        catch { Write-Warn "Could not open the browser. Visit $AuthUrl manually." }
    }
    Write-Host ""
    $Key = Read-MaskedInput "Paste your OpenCode Zen API key"
}

if ([string]::IsNullOrEmpty($Key)) {
    Write-Err "No API key provided. Aborting."
    exit 1
}
if (-not ($Key -like "sk-*")) {
    Write-Warn "This key does not start with 'sk-'. Continuing anyway (double-check it is a Zen API key)."
}

[System.Environment]::SetEnvironmentVariable("OPENCODE_ZEN_API_KEY", $Key, "User")
$env:OPENCODE_ZEN_API_KEY = $Key
Write-OK "API key saved to your User environment (OPENCODE_ZEN_API_KEY)."

# --- [4/8] Model selection ------------------------------------------------------
Write-Section "Model"
if ([string]::IsNullOrEmpty($Model)) {
    if ($Interactive) {
        Write-Host ""
        for ($i = 0; $i -lt $FreeModels.Count; $i++) {
            $Tag = if ($i -eq 0) { " (default)" } else { "" }
            Write-Host ("     [{0}] {1}{2}" -f ($i + 1), $FreeModels[$i].Name, $Tag) -ForegroundColor Gray
        }
        Write-Host ""
        $Choice = Read-Host "Select model [1-$($FreeModels.Count)] (Enter = default)"
        $ChoiceNum = 0
        if ($Choice -match '^\d+$') { $ChoiceNum = [int]$Choice }
        if ($ChoiceNum -lt 1 -or $ChoiceNum -gt $FreeModels.Count) { $ChoiceNum = 1 }
        $Model = $FreeModels[$ChoiceNum - 1].Slug
    } else {
        $Model = $FreeModels[0].Slug
    }
}
Write-OK "Using model: $Model"

# --- [5/8] Detect node_repl runtime (Computer Use / plugins) -------------------
Write-Section "Codex MCP runtime"
$NodeRepl = $null
$RuntimeDir = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node"
if (Test-Path $RuntimeDir) {
    $Latest = Get-ChildItem $RuntimeDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($Latest) {
        $Candidate = Join-Path $Latest.FullName "bin\node_repl.exe"
        if (Test-Path $Candidate) { $NodeRepl = $Candidate }
    }
}
if ($NodeRepl) {
    Write-OK "node_repl runtime found (Computer Use / plugins will work)."
} else {
    Write-Warn "node_repl runtime not found - MCP tools will be skipped (CLI still works)."
}

# --- [6/8] Back up + generate config.toml --------------------------------------
Write-Section "Configuration"
$ConfigPath = Join-Path $CodexHome "config.toml"
if (Test-Path $ConfigPath) {
    $Backup = "$ConfigPath.bak-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"
    Copy-Item $ConfigPath $Backup
    Write-Info "Backed up existing config to $Backup"
}

$CatalogPath = (Join-Path $CodexHome "model-catalog.json") -replace "'", "''"

$Config = @'
# === CHANGE MODEL HERE ===
# Free: big-pickle, deepseek-v4-flash-free, mimo-v2.5-free, ling-3.0-flash-free,
#       nemotron-3-ultra-free, north-mini-code-free, laguna-s-2.1-free
# Paid: gpt-5.6-sol, deepseek-v4-flash, glm-5.2, minimax-m3, kimi-k3, qwen3.6-plus
model = "{1}"

# === CHANGE PROVIDER HERE ===
model_provider = "opencode-zen"

openai_base_url = "http://localhost:{0}/v1"

model_catalog_json = '{2}'

[model_providers.opencode-zen]
name = "OpenCode Zen"
base_url = "http://localhost:{0}/v1"
wire_api = "responses"
stream_idle_timeout_ms = 120000
requires_openai_auth = false
'@ -f $Port, $Model, $CatalogPath

if ($NodeRepl) {
    $Config += @"

[mcp_servers.node_repl]
command = '$NodeRepl'
args = []
startup_timeout_sec = 120

"@
}

[System.IO.File]::WriteAllText($ConfigPath, $Config)
Write-OK "config.toml written to $ConfigPath"

# --- [7/8] (Re)start the proxy --------------------------------------------------
Write-Section "Proxy"
if (-not $NoStart) {
    try {
        $Conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($Conn) {
            $Procs = $Conn | Select-Object -ExpandProperty OwningProcess -Unique
            foreach ($p in $Procs) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
            Write-Info "Stopped previous process on port $Port"
            Start-Sleep -Milliseconds 500
        }
    } catch {
        Write-Warn "Could not inspect port $Port (continuing anyway)."
    }

    $ProxyScript = Join-Path $CodexHome "responses-proxy.js"
    Start-Process -FilePath $node.Source -ArgumentList "`"$ProxyScript`"" -WorkingDirectory $CodexHome -WindowStyle Hidden

    $Healthy = $false
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $h = Invoke-RestMethod "http://localhost:$Port/health" -TimeoutSec 2
            if ($h.status -eq "ok") { $Healthy = $true; break }
        } catch { Start-Sleep -Milliseconds 500 }
    }
    if ($Healthy) {
        Write-OK "Proxy is UP at http://localhost:$Port/health"
    } else {
        Write-Err "Proxy did not answer health check on port $Port."
        Write-Warn "Check the log at $CodexHome\proxy-debug.log"
    }
} else {
    Write-Warn "Skipped proxy start (-NoStart). Launch it later with:"
    Write-Host ("       powershell -ExecutionPolicy Bypass -File `"$CodexHome\start-proxy.ps1`"") -ForegroundColor Cyan
}

# --- [8/8] Summary --------------------------------------------------------------
Write-Section "Done"
Write-Host "   1. Fully quit and restart the OpenAI Codex desktop app (if running)." -ForegroundColor Gray
Write-Host "   2. Or test the CLI immediately:" -ForegroundColor Gray
Write-Host ("      codex exec -c model=$Model -c model_provider=opencode-zen `"say hello`"") -ForegroundColor Cyan
Write-Host "   3. Change the model/provider in config.toml any time." -ForegroundColor Gray
Write-Host ("   4. Logs: $CodexHome\proxy-debug.log") -ForegroundColor Gray
Write-Host ""
Write-Host "  Setup complete. Happy hacking!" -ForegroundColor Green
Write-Host ""
