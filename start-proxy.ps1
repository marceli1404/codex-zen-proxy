# Launch the Responses <-> Chat Completions bridge.
# Reads OPENCODE_ZEN_API_KEY from the Windows User environment (set by setup.ps1).
# Idempotent: if the proxy is already listening on the configured port, exits 0
# (safe to run from a logon scheduled task on every reboot).
$env:OPENCODE_ZEN_API_KEY = [System.Environment]::GetEnvironmentVariable("OPENCODE_ZEN_API_KEY", "User")
if ([string]::IsNullOrEmpty($env:OPENCODE_ZEN_API_KEY)) {
    Write-Host "ERROR: OPENCODE_ZEN_API_KEY is not set in the User environment." -ForegroundColor Red
    Write-Host "Run setup.ps1 first, or set it manually." -ForegroundColor Yellow
    exit 1
}
$Port = 4001
if ($env:CODEX_ZEN_PORT) { $Port = [int]$env:CODEX_ZEN_PORT }
$Already = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($Already) {
    Write-Host "Proxy already listening on port $Port - nothing to do." -ForegroundColor Green
    exit 0
}
node "$PSScriptRoot\responses-proxy.js"
