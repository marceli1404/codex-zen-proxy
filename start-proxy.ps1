# Launch the Responses <-> Chat Completions bridge.
# Reads OPENCODE_ZEN_API_KEY from the Windows User environment (set by setup.ps1).
$env:OPENCODE_ZEN_API_KEY = [System.Environment]::GetEnvironmentVariable("OPENCODE_ZEN_API_KEY", "User")
if ([string]::IsNullOrEmpty($env:OPENCODE_ZEN_API_KEY)) {
    Write-Host "ERROR: OPENCODE_ZEN_API_KEY is not set in the User environment." -ForegroundColor Red
    Write-Host "Run setup.ps1 first, or set it manually." -ForegroundColor Yellow
    exit 1
}
node "$PSScriptRoot\responses-proxy.js"
