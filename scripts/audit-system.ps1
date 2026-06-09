#Requires -Version 5.1
<#
.SYNOPSIS
  Baseline audit for Grok Build on Windows.
.DESCRIPTION
  Collects hardware, OS, power, Grok, dev tools, and terminal settings.
  Writes a timestamped report to reports/ and prints a summary.
#>
param(
    [string]$ReportDir = (Join-Path $PSScriptRoot "..\reports")
)

$ErrorActionPreference = "SilentlyContinue"
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$reportPath = Join-Path $ReportDir "audit-$timestamp.txt"

function Write-Section($title) {
    $line = "`n=== $title ===`n"
    $script:report += $line
    Write-Host $line -ForegroundColor Cyan
}

$report = @()
$report += "Grok Build PC Audit"
$report += "Generated: $(Get-Date -Format o)"
$report += "Machine: $env:COMPUTERNAME"
$report += "User: $env:USERNAME"

Write-Section "Hardware"
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed
$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$gpu = Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, @{N='VRAM_GB';E={[math]::Round($_.AdapterRAM/1GB,2)}}
$report += ($cpu | Format-List | Out-String)
$report += "Total RAM: ${ram} GB"
$report += ($gpu | Format-List | Out-String)

Write-Section "Operating System"
$os = Get-CimInstance Win32_OperatingSystem
$report += "OS: $($os.Caption) $($os.Version) Build $($os.BuildNumber)"
$report += "Uptime: $([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)) hours"

Write-Section "Storage"
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $freePct = if ($_.Size -gt 0) { [math]::Round(100 * $_.FreeSpace / $_.Size, 1) } else { 0 }
    $report += "$($_.DeviceID)  Size: $([math]::Round($_.Size/1GB,1)) GB  Free: $([math]::Round($_.FreeSpace/1GB,1)) GB ($freePct%)"
}

Write-Section "Power Plan"
$active = powercfg /GETACTIVESCHEME
$report += $active
$report += ""
$report += (powercfg /LIST)

Write-Section "Grok Build"
$grokBin = Join-Path $env:USERPROFILE ".grok\bin\grok.exe"
if (Test-Path $grokBin) {
    $report += (& $grokBin --version 2>&1 | Out-String).Trim()
    $grokHome = Join-Path $env:USERPROFILE ".grok"
    $report += "GROK_HOME: $grokHome"
    $report += "config.toml exists: $(Test-Path (Join-Path $grokHome 'config.toml'))"
    $report += "pager.toml exists: $(Test-Path (Join-Path $grokHome 'pager.toml'))"
    if (Test-Path (Join-Path $grokHome 'config.toml')) {
        $report += "`n--- ~/.grok/config.toml ---"
        $report += Get-Content (Join-Path $grokHome 'config.toml') -Raw
    }
} else {
    $report += "grok.exe not found at $grokBin"
}
$report += "GROK in PATH: $(if (Get-Command grok -ErrorAction SilentlyContinue) { 'yes' } else { 'no' })"

Write-Section "Dev Tools"
$tools = @('git', 'node', 'npm', 'python', 'cargo', 'rustc', 'wsl', 'wt', 'code')
foreach ($tool in $tools) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        $ver = switch ($tool) {
            'git' { (& git --version 2>&1) }
            'node' { (& node --version 2>&1) }
            'npm' { (& npm --version 2>&1) }
            'python' { (& python --version 2>&1) }
            'cargo' { (& cargo --version 2>&1) }
            'rustc' { (& rustc --version 2>&1) }
            'wsl' { (& wsl --status 2>&1 | Select-Object -First 3 | Out-String).Trim() }
            default { $cmd.Source }
        }
        $report += "$tool : $ver"
    } else {
        $report += "$tool : not installed"
    }
}

Write-Section "Terminal Environment"
$report += "TERM_PROGRAM: $env:TERM_PROGRAM"
$report += "WT_SESSION: $env:WT_SESSION"
$report += "COLORTERM: $env:COLORTERM"
$report += "Shell: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"

$wtSettings = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
$wtSettingsPreview = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
foreach ($path in @($wtSettings, $wtSettingsPreview)) {
    if (Test-Path $path) {
        $report += "Windows Terminal settings: $path"
        break
    }
}

Write-Section "Windows Defender Exclusions"
$mp = Get-MpPreference -ErrorAction SilentlyContinue
if ($mp) {
    $report += "Exclusion paths:"
    if ($mp.ExclusionPath) { $mp.ExclusionPath | ForEach-Object { $report += "  $_" } } else { $report += "  (none)" }
} else {
    $report += "Unable to read Defender preferences (may need admin)"
}

Write-Section "Startup Impact (top 15 by estimated impact)"
Get-CimInstance Win32_StartupCommand |
    Select-Object Name, Command, Location -First 15 |
    Format-Table -AutoSize |
    Out-String |
    ForEach-Object { $report += $_ }

Write-Section "Recommendations"
$issues = @()
if ($active -match "Power saver|a1841308-3541-4fab-bc81-f71556f20b4a") {
    $issues += "[HIGH] Power plan is Power Saver - switch to Balanced or High Performance for AI dev work."
}
if (-not $env:COLORTERM) {
    $issues += "[MED]  COLORTERM not set - add COLORTERM=truecolor for Windows Terminal profiles."
}
if (-not (Get-Command grok -ErrorAction SilentlyContinue)) {
    $issues += "[MED]  grok not on PATH - add %USERPROFILE%\.grok\bin to User PATH."
}
if ($issues.Count -eq 0) {
    $report += "No critical issues detected. Review Grok config and Defender exclusions for fine-tuning."
} else {
    $issues | ForEach-Object { $report += $_ }
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$report -join "`n" | Set-Content -Path $reportPath -Encoding UTF8

Write-Host "`nReport saved: $reportPath" -ForegroundColor Green
if ($issues.Count -gt 0) {
    Write-Host "`nTop issues:" -ForegroundColor Yellow
    $issues | ForEach-Object { Write-Host "  $_" }
}