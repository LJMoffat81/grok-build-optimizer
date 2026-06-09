#Requires -Version 5.1
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if (-not $env:COLORTERM) {
    $env:COLORTERM = [Environment]::GetEnvironmentVariable("COLORTERM", "User")
}
Write-Host "Launching Grok in $projectRoot" -ForegroundColor Cyan
Write-Host "Tip: run /terminal-setup after launch to verify your terminal." -ForegroundColor DarkGray
& grok --cwd $projectRoot