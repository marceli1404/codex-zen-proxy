# =============================================================================
# Codex <-> OpenCode Zen bridge - one-command setup
#
# Installs the Responses-API translation proxy into ~/.codex, generates a
# config.toml that points Codex at it, saves your Zen API key, and starts the
# proxy.
#
# Usage (interactive -> opens the graphical installer; -Cli forces the
# terminal UI; non-interactive shells fall back to the terminal UI):
#
#   git clone https://github.com/marceli1404/codex-zen-proxy && cd codex-zen-proxy
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#
#   # or the fully single-line form:
#   powershell -Command "$f = Join-Path $env:TEMP setup.ps1; irm 'https://raw.githubusercontent.com/marceli1404/codex-zen-proxy/main/setup.ps1' -OutFile $f; & $f"
#
# Options:
#   -ApiKey   <key>   OpenCode Zen API key (skips the key prompt)
#   -Model    <slug>  Default model, e.g. mimo-v2.5-free, big-pickle
#   -Port     <int>   Proxy listen port (default 4001)
#   -NoStart          Install/configure only, do not launch the proxy
#   -Cli              Force the terminal UI (no GUI window)
#   -GuiSmoke         (internal) build the GUI without showing it
#   -GuiProbe         (internal) build the GUI, populate the quota bars, print JSON, exit
# =============================================================================

[CmdletBinding()]
param(
    [string]$ApiKey = "",
    [string]$Model = "",
    [int]$Port = 4001,
    [switch]$NoStart,
    [switch]$Cli,
    [switch]$GuiSmoke,
    [switch]$GuiProbe
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Constants + data
# -----------------------------------------------------------------------------
$AuthUrl      = "https://opencode.ai/auth"
$GithubRepo   = "https://raw.githubusercontent.com/marceli1404/codex-zen-proxy/main"
$CompanionFiles = @("responses-proxy.js", "start-proxy.ps1", "model-catalog.json")

$FreeModels = @(
    @{ Slug = "mimo-v2.5-free";         Name = "Mimo 2.5 (free) - balanced all-rounder (default)" },
    @{ Slug = "big-pickle";             Name = "big-pickle (free) - general purpose" },
    @{ Slug = "deepseek-v4-flash-free"; Name = "DeepSeek V4 Flash (free) - fast" },
    @{ Slug = "ling-3.0-flash-free";    Name = "Ling 3.0 Flash (free)" },
    @{ Slug = "nemotron-3-ultra-free";  Name = "Nemotron 3 Ultra (free)" },
    @{ Slug = "north-mini-code-free";   Name = "North Mini Code (free) - coding focused" },
    @{ Slug = "laguna-s-2.1-free";      Name = "Laguna S 2.1 (free)" }
)

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------
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

function Get-SavedKey {
    return [System.Environment]::GetEnvironmentVariable("OPENCODE_ZEN_API_KEY", "User")
}

function Get-ResolvedCodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return Join-Path $env:USERPROFILE ".codex"
}

function Write-ConsoleLine {
    param([string]$Level, [string]$Msg)
    switch ($Level) {
        "ok"   { Write-Host ("   [OK]   " + $Msg) -ForegroundColor Green }
        "warn" { Write-Host ("   [!]    " + $Msg) -ForegroundColor Yellow }
        "err"  { Write-Host ("   [ERR]  " + $Msg) -ForegroundColor Red }
        default { Write-Host ("   [..]   " + $Msg) -ForegroundColor Gray }
    }
}

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host ("  " + ("─" * 58)) -ForegroundColor DarkCyan
    Write-Host ("  " + $Title) -ForegroundColor Cyan
}

function Write-CliBanner {
    Write-Host ""
    Write-Host "   ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "   ║                                                          ║" -ForegroundColor Cyan
    Write-Host "   ║   Codex  <->  OpenCode Zen                               ║" -ForegroundColor Cyan
    Write-Host "   ║   one-command bridge installer                           ║" -ForegroundColor Cyan
    Write-Host "   ║                                                          ║" -ForegroundColor Cyan
    Write-Host "   ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-ResultBox {
    param([string]$Title, [string[]]$Lines)
    $w = $Title.Length
    foreach ($l in $Lines) { if ($l.Length -gt $w) { $w = $l.Length } }
    $w = [Math]::Min($w + 4, 70)
    Write-Host ""
    Write-Host ("  " + "╔" + ("═" * ($w - 2)) + "╗") -ForegroundColor Cyan
    Write-Host ("  " + "║ " + $Title.PadRight($w - 4) + " ║") -ForegroundColor Cyan
    Write-Host ("  " + "╠" + ("═" * ($w - 2)) + "╣") -ForegroundColor Cyan
    foreach ($l in $Lines) {
        $line = $l
        if ($line.Length -gt ($w - 4)) { $line = $line.Substring(0, $w - 5) + "…" }
        Write-Host ("  " + "║ " + $line.PadRight($w - 4) + " ║") -ForegroundColor Gray
    }
    Write-Host ("  " + "╚" + ("═" * ($w - 2)) + "╝") -ForegroundColor Cyan
    Write-Host ""
}

# ---- Zen free-quota helpers ------------------------------------------------
# Zen has no public quota API, so the bar is measured by the local proxy
# (responses-proxy.js): request count + tokens per UTC day via GET /usage.

function Format-TokenCount {
    param([long]$N)
    if ($N -ge 1000000000) { return ("{0:0.#}B" -f ($N / 1e9)) }
    if ($N -ge 1000000)    { return ("{0:0.#}M" -f ($N / 1e6)) }
    if ($N -ge 1000)       { return ("{0:0.#}K" -f ($N / 1e3)) }
    return "$N"
}

function Get-ZenUsage {
    param([int]$Port = 4001)
    try {
        return Invoke-RestMethod "http://localhost:$Port/v1/usage" -TimeoutSec 4
    } catch {
        return $null
    }
}

function Get-UsagePercent {
    param([long]$Used, [long]$Limit)
    if ($Limit -le 0) { return 0 }
    return [Math]::Min(100, [Math]::Max(0, [int](100 * $Used / $Limit)))
}

function Get-UsageColor {
    param([int]$Pct)
    if ($Pct -lt 50) { return "Green" }
    if ($Pct -lt 80) { return "Yellow" }
    return "Red"
}

function Write-UsageBar {
    param([object]$Usage, [int]$Port = 4001)
    if ($null -eq $Usage) {
        Write-ConsoleLine "warn" "Free quota: proxy not running on port $Port (starts after install or via start-proxy.ps1)."
        return
    }
    $reqPct = Get-UsagePercent -Used $Usage.requests -Limit $Usage.limits.requests
    $tokPct = Get-UsagePercent -Used $Usage.totalTokens -Limit $Usage.limits.tokens
    $reqFill = [int](20 * $reqPct / 100)
    $tokFill = [int](20 * $tokPct / 100)
    Write-Host ("   Requests : [" + ("█" * $reqFill) + ("░" * (20 - $reqFill)) + "] {0,3}%  {1} / {2} today" -f $reqPct, $Usage.requests, $Usage.limits.requests) -ForegroundColor (Get-UsageColor $reqPct)
    Write-Host ("   Tokens   : [" + ("█" * $tokFill) + ("░" * (20 - $tokFill)) + "] {0,3}%  {1} / {2} free today (day {3}, resets 00:00 UTC)" -f $tokPct, (Format-TokenCount $Usage.totalTokens), (Format-TokenCount $Usage.limits.tokens), $Usage.day) -ForegroundColor (Get-UsageColor $tokPct)
    Write-ConsoleLine "info" ("Limits (~{0} req / {1} tok per day) are community-observed free-tier numbers - tune via CODEX_ZEN_REQ_LIMIT / CODEX_ZEN_TOKEN_LIMIT." -f $Usage.limits.requests, $Usage.limits.tokens)
}

# -----------------------------------------------------------------------------
# Core install routine - shared by the GUI and the terminal UI.
# Emits progress via $OnProgress (percent 0-100) and log lines via
# $OnLog($level, $msg). Returns a result hashtable.
# -----------------------------------------------------------------------------
function Invoke-BridgeInstall {
    param(
        [string]$InstallApiKey,
        [string]$InstallModel,
        [int]$InstallPort,
        [bool]$StartProxy,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress
    )

    $CodexHome = Get-ResolvedCodexHome
    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null

    # --- files ---
    $OnProgress.Invoke(5)
    $SrcDir = $PSScriptRoot
    $NeedsFetch = [string]::IsNullOrEmpty($SrcDir) -or -not (Test-Path (Join-Path $SrcDir "responses-proxy.js"))
    if ($NeedsFetch) {
        $SrcDir = Join-Path $env:TEMP "codex-zen-proxy"
        New-Item -ItemType Directory -Force -Path $SrcDir | Out-Null
        $OnLog.Invoke("info", "Downloading bridge files from GitHub...")
        foreach ($f in $CompanionFiles) {
            Invoke-WebRequest "$GithubRepo/$f" -OutFile (Join-Path $SrcDir $f)
        }
    }
    foreach ($f in $CompanionFiles) {
        Copy-Item (Join-Path $SrcDir $f) (Join-Path $CodexHome $f) -Force
    }
    $OnLog.Invoke("ok", "Bridge files installed to $CodexHome")
    $OnProgress.Invoke(15)

    # --- node ---
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        $OnLog.Invoke("err", "Node.js was not found.")
        throw "Node.js is required - install it from https://nodejs.org and re-run."
    }
    $OnLog.Invoke("ok", "Node.js " + (& $node.Source --version))
    $OnProgress.Invoke(25)

    # --- api key ---
    if ([string]::IsNullOrEmpty($InstallApiKey)) {
        $OnLog.Invoke("err", "No API key provided.")
        throw "No OpenCode Zen API key. Get one at $AuthUrl and pass it with -ApiKey."
    }
    if (-not ($InstallApiKey -like "sk-*")) {
        $OnLog.Invoke("warn", "Key does not start with 'sk-' - continuing (double-check it is a Zen key).")
    }
    if ($InstallApiKey -match "(?i)(test|dummy|fake|placeholder|example)" -or $InstallApiKey.Length -lt 40) {
        $OnLog.Invoke("err", "Refusing to save a test/dummy API key (len $($InstallApiKey.Length), must be >= 40 chars).")
        throw "API key 'sk-$($InstallApiKey.Substring(3, [Math]::Min(5, $InstallApiKey.Length - 3)))...' looks like a test or example key. Get a real key at $AuthUrl."
    }
    $DefaultHome = Join-Path $env:USERPROFILE ".codex"
    if ($CodexHome -eq $DefaultHome) {
        [System.Environment]::SetEnvironmentVariable("OPENCODE_ZEN_API_KEY", $InstallApiKey, "User")
        $env:OPENCODE_ZEN_API_KEY = $InstallApiKey
        $OnLog.Invoke("ok", "API key saved to your User environment (OPENCODE_ZEN_API_KEY).")
    } else {
        $env:OPENCODE_ZEN_API_KEY = $InstallApiKey
        $OnLog.Invoke("info", "CODEX_HOME is overridden - NOT touching the User env key (set OPENCODE_ZEN_API_KEY yourself).")
    }
    $OnProgress.Invoke(40)

    # --- model ---
    $OnLog.Invoke("ok", "Using model: $InstallModel")
    $OnProgress.Invoke(55)

    # --- node_repl runtime ---
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
        $OnLog.Invoke("ok", "node_repl runtime found (Computer Use / plugins will work).")
    } else {
        $OnLog.Invoke("warn", "node_repl runtime not found - MCP tools will be skipped (CLI still works).")
    }
    $OnProgress.Invoke(70)

    # --- config.toml ---
    $ConfigPath = Join-Path $CodexHome "config.toml"
    if (Test-Path $ConfigPath) {
        $Backup = "$ConfigPath.bak-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"
        Copy-Item $ConfigPath $Backup
        $OnLog.Invoke("info", "Backed up existing config to $Backup")
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
'@ -f $InstallPort, $InstallModel, $CatalogPath

    if ($NodeRepl) {
        $Config += @"

[mcp_servers.node_repl]
command = '$NodeRepl'
args = []
startup_timeout_sec = 120

"@
    }
    [System.IO.File]::WriteAllText($ConfigPath, $Config)
    $OnLog.Invoke("ok", "config.toml written to $ConfigPath")
    $OnProgress.Invoke(85)

    # --- proxy ---
    $Healthy = $false
    if ($StartProxy) {
        try {
            $Conn = Get-NetTCPConnection -LocalPort $InstallPort -State Listen -ErrorAction SilentlyContinue
            if ($Conn) {
                $Procs = $Conn | Select-Object -ExpandProperty OwningProcess -Unique
                foreach ($p in $Procs) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
                $OnLog.Invoke("info", "Stopped previous process on port $InstallPort")
                Start-Sleep -Milliseconds 500
            }
        } catch {
            $OnLog.Invoke("warn", "Could not inspect port $InstallPort (continuing anyway).")
        }
        $ProxyScript = Join-Path $CodexHome "responses-proxy.js"
        Start-Process -FilePath $node.Source -ArgumentList "`"$ProxyScript`"" -WorkingDirectory $CodexHome -WindowStyle Hidden
        for ($i = 0; $i -lt 20; $i++) {
            try {
                $h = Invoke-RestMethod "http://localhost:$InstallPort/health" -TimeoutSec 2
                if ($h.status -eq "ok") { $Healthy = $true; break }
            } catch { Start-Sleep -Milliseconds 500 }
        }
        if ($Healthy) {
            $OnLog.Invoke("ok", "Proxy is UP at http://localhost:$InstallPort/health")
        } else {
            $OnLog.Invoke("err", "Proxy did not answer health check on port $InstallPort.")
            $OnLog.Invoke("info", "Check the log at $CodexHome\proxy-debug.log")
        }
    } else {
        $OnLog.Invoke("warn", "Skipped proxy start. Launch it later with start-proxy.ps1.")
    }
    $OnProgress.Invoke(100)

    return @{
        Healthy   = $Healthy
        CodexHome = $CodexHome
        Port      = $InstallPort
        Model     = $InstallModel
    }
}

# -----------------------------------------------------------------------------
# Terminal UI
# -----------------------------------------------------------------------------
function Start-CliInstaller {
    param([string]$ApiKey, [string]$Model, [int]$Port, [bool]$NoStart)

    Write-CliBanner
    $Interactive = Test-Interactive
    $CodexHome = Get-ResolvedCodexHome

    # ---- free quota section (measured by the local proxy) ----
    Write-SectionHeader "Free quota today (free models)"
    Write-UsageBar -Usage (Get-ZenUsage -Port $Port) -Port $Port

    # ---- API key section ----
    Write-SectionHeader "OpenCode Zen API key"
    $Key = $ApiKey
    if ([string]::IsNullOrEmpty($Key)) { $Key = Get-SavedKey }
    if (-not [string]::IsNullOrEmpty($Key)) {
        if ($ApiKey) { Write-ConsoleLine "ok" "Using API key from -ApiKey: $(Get-KeyPreview $Key)" }
        else         { Write-ConsoleLine "ok" "Found a saved API key: $(Get-KeyPreview $Key)" }
        if ($Interactive -and $ApiKey -eq "") {
            $Change = Read-Host "Use this key? [Y/n]"
            if ($Change -match '^[nN]') { $Key = "" }
        }
    }
    if ([string]::IsNullOrEmpty($Key)) {
        if (-not $Interactive) {
            Write-ConsoleLine "err" "No saved OPENCODE_ZEN_API_KEY and the shell is non-interactive."
            Write-ConsoleLine "warn" "Get a key at $AuthUrl, then re-run with: -ApiKey sk-xxxx"
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
            try { Start-Process $AuthUrl; Write-ConsoleLine "info" "Opened $AuthUrl - log in and copy your key." }
            catch { Write-ConsoleLine "warn" "Could not open the browser. Visit $AuthUrl manually." }
        }
        Write-Host ""
        $Key = Read-MaskedInput "Paste your OpenCode Zen API key"
    }
    if ([string]::IsNullOrEmpty($Key)) {
        Write-ConsoleLine "err" "No API key provided. Aborting."
        exit 1
    }
    Write-ConsoleLine "ok" "API key ready."

    # ---- model section ----
    Write-SectionHeader "Model"
    if ([string]::IsNullOrEmpty($Model)) {
        if ($Interactive) {
            Write-Host ""
            for ($i = 0; $i -lt $FreeModels.Count; $i++) {
                $Tag = if ($i -eq 0) { "  (default)" } else { "" }
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
    Write-ConsoleLine "ok" "Using model: $Model"

    # ---- proxy section ----
    $StartProxy = -not $NoStart
    if ($Interactive -and -not $NoStart) {
        $Ans = Read-Host "Start the proxy now? [Y/n]"
        if ($Ans -match '^[nN]') { $StartProxy = $false }
    }

    # ---- run install ----
    Write-SectionHeader "Installing"
    $Bar = { param($pct) try { [Console]::Write("`r   [" + ("█" * [int]($pct / 4)) + ("·" * (25 - [int]($pct / 4))) + "] $pct%") } catch {} }
    $Result = $null
    try {
        $Result = Invoke-BridgeInstall -InstallApiKey $Key -InstallModel $Model -InstallPort $Port -StartProxy $StartProxy -OnLog { param($l, $m) Write-ConsoleLine $l $m } -OnProgress $Bar
        Write-Host ""
        Write-Host ""
    } catch {
        Write-Host ""
        Write-ConsoleLine "err" $_.Exception.Message
        exit 1
    }

    # ---- summary ----
    $Status = if ($Result.Healthy) { "UP" } elseif ($StartProxy) { "DID NOT START (check log)" } else { "not started (configured)" }
    Write-ResultBox -Title "Setup complete" -Lines @(
        "Model   : $($Result.Model)"
        "Proxy   : http://localhost:$($Result.Port)/health  [$Status]"
        "Codex   : $($Result.CodexHome)"
        ""
        "1. Fully quit and restart the OpenAI Codex desktop app (if running)."
        "2. Test the CLI: codex exec -c model=$($Result.Model) -c model_provider=opencode-zen `"say hello`""
        "3. Change model/provider any time in config.toml."
        "4. Logs: $($Result.CodexHome)\proxy-debug.log"
    )

    # ---- live quota after install (if the proxy just started) ----
    if ($Result.Healthy) {
        Write-SectionHeader "Free quota today (live)"
        Write-UsageBar -Usage (Get-ZenUsage -Port $Port) -Port $Port
    }
}

# -----------------------------------------------------------------------------
# Graphical UI (WinForms)
# -----------------------------------------------------------------------------
function Show-GuiInstaller {
    param([string]$ExistingKey, [string]$DefaultModel, [int]$DefaultPort, [bool]$StartProxyDefault, [bool]$SmokeTest, [bool]$Probe)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $BG     = [System.Drawing.Color]::FromArgb(15, 23, 42)   # slate-900
    $PANEL  = [System.Drawing.Color]::FromArgb(30, 41, 59)   # slate-800
    $FIELD  = [System.Drawing.Color]::FromArgb(11, 18, 32)   # darker input
    $CYAN   = [System.Drawing.Color]::FromArgb(34, 211, 238)
    $ACCENT = [System.Drawing.Color]::FromArgb(14, 165, 233)
    $GREEN  = [System.Drawing.Color]::FromArgb(74, 222, 128)
    $YELLOW = [System.Drawing.Color]::FromArgb(250, 204, 21)
    $RED    = [System.Drawing.Color]::FromArgb(248, 113, 113)
    $TEXT   = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $MUTED  = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $BTN    = [System.Drawing.Color]::FromArgb(51, 65, 85)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Codex <-> OpenCode Zen Bridge Installer"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.BackColor = $BG
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.ClientSize = New-Object System.Drawing.Size(600, 780)

    # ---- banner ----
    $accentBar = New-Object System.Windows.Forms.Panel
    $accentBar.Location = New-Object System.Drawing.Point(0, 0)
    $accentBar.Size = New-Object System.Drawing.Size(600, 4)
    $accentBar.BackColor = $CYAN
    $form.Controls.Add($accentBar)

    $title = New-Object System.Windows.Forms.Label
    $title.Location = New-Object System.Drawing.Point(24, 16)
    $title.Size = New-Object System.Drawing.Size(552, 34)
    $title.Text = "Codex  <->  OpenCode Zen  Bridge"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $TEXT
    $form.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Location = New-Object System.Drawing.Point(24, 52)
    $subtitle.Size = New-Object System.Drawing.Size(552, 22)
    $subtitle.Text = "Run the OpenAI Codex CLI / desktop app on OpenCode Zen models."
    $subtitle.ForeColor = $MUTED
    $form.Controls.Add($subtitle)

    # ---- section header helper ----
    $makeSection = {
        param([int]$Y, [string]$Text)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Location = New-Object System.Drawing.Point(24, $Y)
        $lbl.Size = New-Object System.Drawing.Size(552, 20)
        $lbl.Text = $Text
        $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $lbl.ForeColor = $CYAN
        return $lbl
    }

    # ---- 1. API key ----
    $form.Controls.Add($( & $makeSection 86 "1.  OPENCODE ZEN API KEY"))

    $keyBox = New-Object System.Windows.Forms.TextBox
    $keyBox.Location = New-Object System.Drawing.Point(24, 110)
    $keyBox.Size = New-Object System.Drawing.Size(400, 24)
    $keyBox.UseSystemPasswordChar = $true
    $keyBox.BackColor = $FIELD
    $keyBox.ForeColor = $TEXT
    $keyBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    if (-not [string]::IsNullOrEmpty($ExistingKey)) { $keyBox.Text = $ExistingKey }
    $form.Controls.Add($keyBox)

    $showCheck = New-Object System.Windows.Forms.CheckBox
    $showCheck.Location = New-Object System.Drawing.Point(432, 111)
    $showCheck.Size = New-Object System.Drawing.Size(70, 22)
    $showCheck.Text = "Show"
    $showCheck.ForeColor = $MUTED
    $showCheck.Add_CheckedChanged({
        $keyBox.UseSystemPasswordChar = -not $showCheck.Checked
    })
    $form.Controls.Add($showCheck)

    if (-not [string]::IsNullOrEmpty($ExistingKey)) {
        $preview = New-Object System.Windows.Forms.Label
        $preview.Location = New-Object System.Drawing.Point(24, 140)
        $preview.Size = New-Object System.Drawing.Size(552, 20)
        $preview.Text = "Saved key: $(Get-KeyPreview $ExistingKey)   (edit the field above to replace it)"
        $preview.ForeColor = $MUTED
        $form.Controls.Add($preview)
    }

    $getKeyLink = New-Object System.Windows.Forms.LinkLabel
    $getKeyLink.Location = New-Object System.Drawing.Point(24, 164)
    $getKeyLink.Size = New-Object System.Drawing.Size(340, 22)
    $getKeyLink.Text = "Don't have a key?  Get one in about 2 minutes"
    $getKeyLink.LinkColor = $CYAN
    $getKeyLink.ActiveLinkColor = $ACCENT
    $getKeyLink.Add_LinkClicked({
        try { Start-Process $AuthUrl } catch {}
    })
    $form.Controls.Add($getKeyLink)

    # ---- 2. Model ----
    $form.Controls.Add($( & $makeSection 198 "2.  MODEL"))
    $modelBox = New-Object System.Windows.Forms.ComboBox
    $modelBox.Location = New-Object System.Drawing.Point(24, 222)
    $modelBox.Size = New-Object System.Drawing.Size(400, 24)
    $modelBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $modelBox.BackColor = $FIELD
    $modelBox.ForeColor = $TEXT
    $modelBox.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    foreach ($m in $FreeModels) { [void]$modelBox.Items.Add($m.Name) }
    $selIdx = 0
    if (-not [string]::IsNullOrEmpty($DefaultModel)) {
        $found = $false
        for ($i = 0; $i -lt $FreeModels.Count; $i++) {
            if ($FreeModels[$i].Slug -eq $DefaultModel) { $selIdx = $i; $found = $true; break }
        }
        if (-not $found) { $selIdx = 0 }
    }
    $modelBox.SelectedIndex = $selIdx
    $form.Controls.Add($modelBox)

    # ---- 3. Port ----
    $form.Controls.Add($( & $makeSection 256 "3.  PROXY PORT"))
    $portBox = New-Object System.Windows.Forms.NumericUpDown
    $portBox.Location = New-Object System.Drawing.Point(24, 280)
    $portBox.Size = New-Object System.Drawing.Size(120, 24)
    $portBox.Minimum = 1024
    $portBox.Maximum = 65535
    $portBox.Value = $DefaultPort
    $portBox.BackColor = $FIELD
    $portBox.ForeColor = $TEXT
    $form.Controls.Add($portBox)

    $startCheck = New-Object System.Windows.Forms.CheckBox
    $startCheck.Location = New-Object System.Drawing.Point(24, 314)
    $startCheck.Size = New-Object System.Drawing.Size(320, 24)
    $startCheck.Text = "Start the proxy when install finishes"
    $startCheck.ForeColor = $TEXT
    $startCheck.Checked = $StartProxyDefault
    $form.Controls.Add($startCheck)

    $homeLbl = New-Object System.Windows.Forms.Label
    $homeLbl.Location = New-Object System.Drawing.Point(24, 342)
    $homeLbl.Size = New-Object System.Drawing.Size(552, 34)
    $homeLbl.Text = "Installs into: $(Get-ResolvedCodexHome)"
    $homeLbl.ForeColor = $MUTED
    $form.Controls.Add($homeLbl)

    # ---- 5. Free quota today ----
    $form.Controls.Add($( & $makeSection 388 "5.  FREE QUOTA TODAY  (measured by your local proxy)"))

    $reqBar = New-Object System.Windows.Forms.ProgressBar
    $reqBar.Location = New-Object System.Drawing.Point(24, 412)
    $reqBar.Size = New-Object System.Drawing.Size(552, 16)
    $reqBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $reqBar.Minimum = 0
    $reqBar.Maximum = 100
    $form.Controls.Add($reqBar)

    $reqLbl = New-Object System.Windows.Forms.Label
    $reqLbl.Location = New-Object System.Drawing.Point(24, 434)
    $reqLbl.Size = New-Object System.Drawing.Size(552, 18)
    $reqLbl.ForeColor = $TEXT
    $reqLbl.Text = "Requests : n/a"
    $form.Controls.Add($reqLbl)

    $tokBar = New-Object System.Windows.Forms.ProgressBar
    $tokBar.Location = New-Object System.Drawing.Point(24, 456)
    $tokBar.Size = New-Object System.Drawing.Size(552, 16)
    $tokBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $tokBar.Minimum = 0
    $tokBar.Maximum = 100
    $form.Controls.Add($tokBar)

    $tokLbl = New-Object System.Windows.Forms.Label
    $tokLbl.Location = New-Object System.Drawing.Point(24, 478)
    $tokLbl.Size = New-Object System.Drawing.Size(552, 18)
    $tokLbl.ForeColor = $TEXT
    $tokLbl.Text = "Tokens   : n/a"
    $form.Controls.Add($tokLbl)

    $usageStatus = New-Object System.Windows.Forms.Label
    $usageStatus.Location = New-Object System.Drawing.Point(24, 502)
    $usageStatus.Size = New-Object System.Drawing.Size(400, 20)
    $usageStatus.ForeColor = $MUTED
    $usageStatus.Text = "Proxy not running yet - start it, then Refresh."
    $form.Controls.Add($usageStatus)

    $refreshLink = New-Object System.Windows.Forms.LinkLabel
    $refreshLink.Location = New-Object System.Drawing.Point(470, 502)
    $refreshLink.Size = New-Object System.Drawing.Size(106, 20)
    $refreshLink.Text = "Refresh"
    $refreshLink.LinkColor = $CYAN
    $refreshLink.ActiveLinkColor = $ACCENT
    $form.Controls.Add($refreshLink)

    $updateUsage = {
        try {
            $pu = Invoke-RestMethod "http://localhost:$([int]$portBox.Value)/v1/usage" -TimeoutSec 3
            $rp = Get-UsagePercent -Used $pu.requests -Limit $pu.limits.requests
            $tp = Get-UsagePercent -Used $pu.totalTokens -Limit $pu.limits.tokens
            $reqBar.Value = $rp
            $tokBar.Value = $tp
            $reqLbl.Text = "Requests : {0} / {1} today  ({2}%)" -f $pu.requests, $pu.limits.requests, $rp
            $tokLbl.Text = "Tokens   : {0} / {1} free today  ({2}%)" -f (Format-TokenCount $pu.totalTokens), (Format-TokenCount $pu.limits.tokens), $tp
            $reqLbl.ForeColor = if ($rp -lt 50) { $GREEN } elseif ($rp -lt 80) { $YELLOW } else { $RED }
            $tokLbl.ForeColor = if ($tp -lt 50) { $GREEN } elseif ($tp -lt 80) { $YELLOW } else { $RED }
            $usageStatus.Text = "Day $($pu.day) - resets at 00:00 UTC - limits are ~$($pu.limits.requests) req / $(Format-TokenCount $pu.limits.tokens) tok"
            $usageStatus.ForeColor = $MUTED
        } catch {
            $reqBar.Value = 0
            $tokBar.Value = 0
            $reqLbl.Text = "Requests : n/a"
            $tokLbl.Text = "Tokens   : n/a"
            $reqLbl.ForeColor = $MUTED
            $tokLbl.ForeColor = $MUTED
            $usageStatus.Text = "Proxy not running on port $([int]$portBox.Value) - start it, then Refresh."
            $usageStatus.ForeColor = $MUTED
        }
    }
    $refreshLink.Add_LinkClicked({ & $updateUsage })
    $portBox.Add_ValueChanged({ & $updateUsage })

    # ---- 6. Install progress ----
    $form.Controls.Add($( & $makeSection 532 "6.  INSTALL PROGRESS"))

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(24, 556)
    $progress.Size = New-Object System.Drawing.Size(552, 20)
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $progress.Minimum = 0
    $progress.Maximum = 100
    $form.Controls.Add($progress)

    $logBox = New-Object System.Windows.Forms.ListBox
    $logBox.Location = New-Object System.Drawing.Point(24, 584)
    $logBox.Size = New-Object System.Drawing.Size(552, 100)
    $logBox.BackColor = $FIELD
    $logBox.ForeColor = $TEXT
    $logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $logBox.IntegralHeight = $false
    $logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $form.Controls.Add($logBox)

    # ---- buttons ----
    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Location = New-Object System.Drawing.Point(24, 710)
    $cancelBtn.Size = New-Object System.Drawing.Size(110, 34)
    $cancelBtn.Text = "Cancel"
    $cancelBtn.BackColor = $BTN
    $cancelBtn.ForeColor = $TEXT
    $cancelBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cancelBtn.FlatAppearance.BorderSize = 0
    $cancelBtn.Add_Click({ $form.Close() })
    $form.Controls.Add($cancelBtn)

    $installBtn = New-Object System.Windows.Forms.Button
    $installBtn.Location = New-Object System.Drawing.Point(466, 710)
    $installBtn.Size = New-Object System.Drawing.Size(110, 34)
    $installBtn.Text = "Install"
    $installBtn.BackColor = $ACCENT
    $installBtn.ForeColor = [System.Drawing.Color]::White
    $installBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $installBtn.FlatAppearance.BorderSize = 0
    $installBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $installBtn.Add_Click({

        $installBtn.Enabled = $false
        $cancelBtn.Enabled = $false

        # ---- UI callbacks (run on the UI thread - synchronous install) ----
        $guiLog = {
            param($level, $msg)
            $marker = switch ($level) {
                "ok"   { "  OK  " }
                "warn" { " [!]  " }
                "err"  { " ERR  " }
                default { " ...  " }
            }
            [void]$logBox.Items.Add($marker + $msg)
            $logBox.TopIndex = $logBox.Items.Count - 1
            $form.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
        }
        $guiProg = {
            param($pct)
            $progress.Value = [Math]::Min(100, [Math]::Max(0, [int]$pct))
            $form.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $key = $keyBox.Text.Trim()
        if ([string]::IsNullOrEmpty($key)) {
            [System.Windows.Forms.MessageBox]::Show($form, "Please paste your OpenCode Zen API key (or click 'Get one' to create it).", "API key required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            $installBtn.Enabled = $true
            $cancelBtn.Enabled = $true
            return
        }

        $modelSlug = $FreeModels[$modelBox.SelectedIndex].Slug
        $portVal = [int]$portBox.Value
        $startIt = $startCheck.Checked

        try {
            $r = Invoke-BridgeInstall -InstallApiKey $key -InstallModel $modelSlug -InstallPort $portVal -StartProxy $startIt -OnLog $guiLog -OnProgress $guiProg

            $status = if ($r.Healthy) { "UP" } elseif ($startIt) { "DID NOT START (check the log file)" } else { "not started (configured)" }
            $summary = "Setup complete!" + [Environment]::NewLine + [Environment]::NewLine +
                "  Model  : $($r.Model)" + [Environment]::NewLine +
                "  Proxy  : http://localhost:$($r.Port)/health   [$status]" + [Environment]::NewLine +
                "  Codex  : $($r.CodexHome)" + [Environment]::NewLine + [Environment]::NewLine +
                "1. Fully quit and restart the OpenAI Codex desktop app (if running)." + [Environment]::NewLine +
                "2. Test the CLI:  codex exec -c model=$($r.Model) -c model_provider=opencode-zen `"say hello`"" + [Environment]::NewLine +
                "3. Change the model/provider any time in config.toml." + [Environment]::NewLine +
                "4. Logs: $($r.CodexHome)\proxy-debug.log"

            [System.Windows.Forms.MessageBox]::Show($form, $summary, "Install complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "Install failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } finally {
            $installBtn.Enabled = $true
            $cancelBtn.Enabled = $true
        }
    })
    $form.Controls.Add($installBtn)

    & $updateUsage

    if ($SmokeTest) {
        $form.Dispose()
        return $true
    }

    if ($Probe) {
        $result = [pscustomobject]@{
            formSize = "$($form.ClientSize.Width)x$($form.ClientSize.Height)"
            controls = $form.Controls.Count
            reqBar   = $reqBar.Value
            tokBar   = $tokBar.Value
            reqLbl   = $reqLbl.Text
            tokLbl   = $tokLbl.Text
            status   = $usageStatus.Text
        }
        $form.Dispose()
        return $result
    }

    [void]$form.ShowDialog()
    $form.Dispose()
    return $true
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
$SavedKey = Get-SavedKey
$DefaultModel = if ($Model) { $Model } else { $FreeModels[0].Slug }

if ($GuiSmoke -or $GuiProbe -or (-not $Cli -and (Test-Interactive))) {
    try {
        $r = Show-GuiInstaller -ExistingKey $SavedKey -DefaultModel $DefaultModel -DefaultPort $Port -StartProxyDefault (-not $NoStart) -SmokeTest $GuiSmoke -Probe $GuiProbe
        if ($GuiProbe) { $r | ConvertTo-Json -Compress }
        exit 0
    } catch {
        Write-Host "   [!]    GUI unavailable ($($_.Exception.Message)). Using the terminal UI." -ForegroundColor Yellow
    }
}

Start-CliInstaller -ApiKey $ApiKey -Model $Model -Port $Port -NoStart $NoStart
