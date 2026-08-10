# =============================================================================
# Switch the active OpenCode Zen model for Codex - instantly, no desktop
# restart. Sets a per-request override on the running proxy (so the very next
# prompt uses the new model) and keeps config.toml in sync for restarts.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File switch-model.ps1            (menu)
#   powershell -ExecutionPolicy Bypass -File switch-model.ps1 -Slug big-pickle
#   powershell -ExecutionPolicy Bypass -File switch-model.ps1 big-pickle (positional)
# =============================================================================
param(
    [string]$Slug = ""
)

$ErrorActionPreference = "Stop"
$ProxyUrl = "http://localhost:4001"

$FreeModels = @(
    @{ Slug = "mimo-v2.5-free";         Name = "Mimo 2.5 (free) - balanced all-rounder (default)" },
    @{ Slug = "big-pickle";             Name = "big-pickle (free) - general purpose" },
    @{ Slug = "deepseek-v4-flash-free"; Name = "DeepSeek V4 Flash (free) - fast" },
    @{ Slug = "ling-3.0-flash-free";    Name = "Ling 3.0 Flash (free)" },
    @{ Slug = "nemotron-3-ultra-free";  Name = "Nemotron 3 Ultra (free)" },
    @{ Slug = "north-mini-code-free";   Name = "North Mini Code (free) - coding focused" },
    @{ Slug = "laguna-s-2.1-free";      Name = "Laguna S 2.1 (free)" }
)

function Test-Interactive {
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

# --- pick the model ----------------------------------------------------------
$Choice = $Slug.Trim()
if (-not $Choice -and (Test-Interactive)) {
    Write-Host ""
    Write-Host "  Codex Zen model switcher (instant, no desktop restart)" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------------"
    for ($i = 0; $i -lt $FreeModels.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $FreeModels[$i].Name)
    }
    Write-Host ("  [0]  <use config.toml model (clear override)>")
    $input = Read-Host "  Choose a model"
    if ($input -eq "0") {
        $Choice = "__CLEAR__"
    } elseif ([int]::TryParse($input, [ref]$null)) {
        $idx = [int]$input
        if ($idx -ge 1 -and $idx -le $FreeModels.Count) { $Choice = $FreeModels[$idx - 1].Slug }
    }
}
if ($Choice -eq "__CLEAR__") {
    try { Invoke-RestMethod -Method Delete "$ProxyUrl/v1/model" -TimeoutSec 5 | Out-Null }
    catch { Write-Host "Proxy not reachable on $ProxyUrl - only config.toml was updated." -ForegroundColor Yellow }
    $Msg = "Override cleared - using the model from config.toml"
} else {
    if (-not $Choice) {
        Write-Host "No model chosen and stdin is not interactive - pass a slug, e.g. switch-model.ps1 -Slug big-pickle" -ForegroundColor Yellow
        exit 1
    }
    $Valid = $FreeModels.Slug -contains $Choice
    if (-not $Valid) {
        Write-Host "Unknown model '$Choice'. Free models: $($FreeModels.Slug -join ', ')" -ForegroundColor Red
        exit 1
    }
    try {
        $r = Invoke-RestMethod -Method Put "$ProxyUrl/v1/model?slug=$([uri]::EscapeDataString($Choice))" -TimeoutSec 5
        $Msg = "Model set to $($r.model)"
    } catch {
        Write-Host "Proxy not reachable on $ProxyUrl - the model was NOT applied (only config.toml updated)." -ForegroundColor Yellow
        $Msg = "Model $Choice queued in config.toml only (proxy down)"
    }
}

# --- keep config.toml in sync (display + restarts) --------------------------
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$ConfigPath = Join-Path $CodexHome "config.toml"
if (Test-Path $ConfigPath) {
    $cfg = [System.IO.File]::ReadAllText($ConfigPath)
    if ($Choice -eq "__CLEAR__") {
        # leave the config.toml model alone; only the override is cleared
    } else {
        $new = [regex]::Replace($cfg, "(?m)^model\s*=.*$", "model = `"$Choice`"")
        if ($new -ne $cfg) {
            [System.IO.File]::WriteAllText($ConfigPath, $new)
            Write-Host "config.toml updated (model = `"$Choice`")" -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host "config.toml not found at $ConfigPath - skipping." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  $Msg" -ForegroundColor Green
Write-Host "  Next prompt in Codex uses it immediately (no app restart)." -ForegroundColor DarkGray
