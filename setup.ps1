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
#   -ApiKey   <key>   OpenCode Zen API key (if not already saved)
#   -Model    <slug>  Default model, e.g. mimo-v2.5-free, big-pickle (default mimo-v2.5-free)
#   -Port     <int>   Proxy listen port (default 4001)
#   -NoStart          Install/configure only, do not launch the proxy
# =============================================================================

[CmdletBinding()]
param(
    [string]$ApiKey = "",
    [string]$Model = "mimo-v2.5-free",
    [int]$Port = 4001,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"

$GithubRepo = "https://raw.githubusercontent.com/marceli1404/codex-zen-proxy/main"
$CompanionFiles = @("responses-proxy.js", "start-proxy.ps1", "model-catalog.json")

Write-Host "== Codex <-> OpenCode Zen bridge setup ==" -ForegroundColor Cyan

# --- 1. Resolve Codex home + companion file location -------------------------
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null

$SrcDir = $PSScriptRoot
$NeedsFetch = [string]::IsNullOrEmpty($SrcDir) -or -not (Test-Path (Join-Path $SrcDir "responses-proxy.js"))
if ($NeedsFetch) {
    $SrcDir = Join-Path $env:TEMP "codex-zen-proxy"
    New-Item -ItemType Directory -Force -Path $SrcDir | Out-Null
    Write-Host "Downloading bridge files from GitHub..." -ForegroundColor Yellow
    foreach ($f in $CompanionFiles) {
        Invoke-WebRequest "$GithubRepo/$f" -OutFile (Join-Path $SrcDir $f)
    }
}

# --- 2. Check Node.js --------------------------------------------------------
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host "ERROR: Node.js is required but was not found." -ForegroundColor Red
    Write-Host "Install it from https://nodejs.org then re-run this script." -ForegroundColor Yellow
    exit 1
}
Write-Host ("Node.js found: " + (& $node.Source --version)) -ForegroundColor Green

# --- 3. Install bridge files into Codex home ---------------------------------
foreach ($f in $CompanionFiles) {
    Copy-Item (Join-Path $SrcDir $f) (Join-Path $CodexHome $f) -Force
}
Write-Host "Bridge files installed to $CodexHome" -ForegroundColor Green

# --- 4. API key --------------------------------------------------------------
$Key = $ApiKey
if ([string]::IsNullOrEmpty($Key)) {
    $Key = [System.Environment]::GetEnvironmentVariable("OPENCODE_ZEN_API_KEY", "User")
}
if ([string]::IsNullOrEmpty($Key)) {
    $Key = Read-Host "Enter your OpenCode Zen API key (will be stored in your User environment)"
}
if ([string]::IsNullOrEmpty($Key)) {
    Write-Host "ERROR: No API key provided. Aborting." -ForegroundColor Red
    exit 1
}
[System.Environment]::SetEnvironmentVariable("OPENCODE_ZEN_API_KEY", $Key, "User")
$env:OPENCODE_ZEN_API_KEY = $Key
Write-Host "API key saved to User environment (OPENCODE_ZEN_API_KEY)." -ForegroundColor Green

# --- 5. Detect the node_repl MCP runtime (Computer Use / plugins) -------------
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
    Write-Host ("node_repl runtime found: " + $NodeRepl) -ForegroundColor Green
} else {
    Write-Host "NOTE: node_repl runtime not found - MCP tools will be skipped (CLI still works)." -ForegroundColor Yellow
}

# --- 6. Back up + generate config.toml ---------------------------------------
$ConfigPath = Join-Path $CodexHome "config.toml"
if (Test-Path $ConfigPath) {
    $Backup = "$ConfigPath.bak-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"
    Copy-Item $ConfigPath $Backup
    Write-Host "Backed up existing config to $Backup" -ForegroundColor Yellow
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
Write-Host "config.toml written to $ConfigPath" -ForegroundColor Green

# --- 7. (Re)start the proxy ---------------------------------------------------
if (-not $NoStart) {
    # Stop anything already listening on the port
    try {
        $Conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($Conn) {
            $Procs = $Conn | Select-Object -ExpandProperty OwningProcess -Unique
            foreach ($p in $Procs) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
            Write-Host "Stopped previous process on port $Port" -ForegroundColor Yellow
            Start-Sleep -Milliseconds 500
        }
    } catch {
        Write-Host "Could not inspect port $Port (continuing anyway)." -ForegroundColor Yellow
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
        Write-Host "Proxy is UP at http://localhost:$Port/health" -ForegroundColor Green
    } else {
        Write-Host "WARNING: proxy did not answer health check on port $Port." -ForegroundColor Red
        Write-Host "Check the log at $CodexHome\proxy-debug.log" -ForegroundColor Yellow
    }
} else {
    Write-Host "Skipped proxy start (-NoStart). Launch it later with:" -ForegroundColor Yellow
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$CodexHome\start-proxy.ps1`"" -ForegroundColor Cyan
}

# --- 8. Summary ---------------------------------------------------------------
Write-Host ""
Write-Host "== Setup complete ==" -ForegroundColor Cyan
Write-Host "1. Fully quit and restart the OpenAI Codex desktop app (if running)."
Write-Host "2. Or test the CLI immediately:"
Write-Host "   codex exec -c model=$Model -c model_provider=opencode-zen `"say hello`""
Write-Host "3. Model/provider is changed in $CodexHome\config.toml."
Write-Host "4. Logs: $CodexHome\proxy-debug.log"
