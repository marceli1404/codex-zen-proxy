# =============================================================================
# Push helper for the codex-zen-proxy repo.
#
# Shows today's free quota bar (measured by the local proxy via GET /v1/usage),
# then commits and pushes all pending changes.
#
# Usage:
#   .\push.ps1                       # auto commit message + push
#   .\push.ps1 -Message "my change"  # custom commit message
# =============================================================================

[CmdletBinding()]
param(
    [string]$Message = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$Port = 4001

function Format-TokenCount {
    param([long]$N)
    if ($N -ge 1000000000) { return ("{0:0.#}B" -f ($N / 1e9)) }
    if ($N -ge 1000000)    { return ("{0:0.#}M" -f ($N / 1e6)) }
    if ($N -ge 1000)       { return ("{0:0.#}K" -f ($N / 1e3)) }
    return "$N"
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

# ---- free quota bar (measured by the local proxy) ----
try {
    $Usage = Invoke-RestMethod "http://localhost:$Port/v1/usage" -TimeoutSec 4
    $reqPct = Get-UsagePercent -Used $Usage.requests -Limit $Usage.limits.requests
    $tokPct = Get-UsagePercent -Used $Usage.totalTokens -Limit $Usage.limits.tokens
    $reqFill = [int](20 * $reqPct / 100)
    $tokFill = [int](20 * $tokPct / 100)
    Write-Host ""
    Write-Host "  Free quota today (free models, via local proxy :$Port)" -ForegroundColor Cyan
    Write-Host ("   Requests : [" + ("█" * $reqFill) + ("░" * (20 - $reqFill)) + "] {0,3}%  {1} / {2} today" -f $reqPct, $Usage.requests, $Usage.limits.requests) -ForegroundColor (Get-UsageColor $reqPct)
    Write-Host ("   Tokens   : [" + ("█" * $tokFill) + ("░" * (20 - $tokFill)) + "] {0,3}%  {1} / {2} free today (day {3}, resets 00:00 UTC)" -f $tokPct, (Format-TokenCount $Usage.totalTokens), (Format-TokenCount $Usage.limits.tokens), $Usage.day) -ForegroundColor (Get-UsageColor $tokPct)
} catch {
    Write-Host "  Free quota: proxy not running on port $Port - start it with start-proxy.ps1." -ForegroundColor Yellow
}

# ---- git status ----
git -C $RepoRoot status --short
$changed = git -C $RepoRoot status --porcelain
if (-not $changed) {
    Write-Host "Nothing to push." -ForegroundColor Green
    exit 0
}

# ---- commit + push ----
if (-not $Message) {
    $Message = "Update codex-zen-proxy ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
}
git -C $RepoRoot add -A
git -C $RepoRoot commit -m $Message
git -C $RepoRoot push
Write-Host "Pushed to GitHub." -ForegroundColor Green
