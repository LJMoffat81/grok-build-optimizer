#Requires -Version 5.1
<#
.SYNOPSIS
  Audit and disable non-essential Windows startup items for dev work.
.PARAMETER WhatIf
  Preview changes without applying them.
.PARAMETER IncludeOptional
  Also disable Teams and MuseHub startup (re-enable manually if needed).
#>
param(
    [switch]$WhatIf,
    [switch]$IncludeOptional
)

$ErrorActionPreference = "Stop"
$reportDir = Join-Path $PSScriptRoot "..\reports"
$backupDir = Join-Path $reportDir "startup-backup-$(Get-Date -Format 'yyyy-MM-dd')"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$changes = [System.Collections.Generic.List[string]]::new()

function Log-Change($msg) {
    $changes.Add($msg)
    $prefix = if ($WhatIf) { "[WhatIf]" } else { "[Applied]" }
    Write-Host "$prefix $msg" -ForegroundColor $(if ($WhatIf) { "Yellow" } else { "Green" })
}

function Backup-RegistryValue($hive, $path, $name) {
    if ($WhatIf) { return }
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $value = Get-ItemProperty -Path $hive -Name $name -ErrorAction SilentlyContinue
    if ($value) {
        $backup = @{
            Hive = $hive
            Path = $path
            Name = $name
            Value = $value.$name
        }
        $backup | ConvertTo-Json | Add-Content (Join-Path $backupDir "registry-backup.jsonl")
    }
}

function Remove-RunKey($hive, $name, $reason) {
    $path = if ($hive -eq "HKCU") { "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" } else { "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" }
    $existing = Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "Not found: $name ($hive) - skipping." -ForegroundColor DarkGray
        return
    }
    if ($hive -eq "HKLM" -and -not $isAdmin) {
        Write-Host "Skipping $name (HKLM requires admin)." -ForegroundColor DarkYellow
        return
    }
    Backup-RegistryValue $path $path $name
    if ($WhatIf) {
        Log-Change "Would remove $hive Run\$name ($reason)"
    } else {
        Remove-ItemProperty -Path $path -Name $name
        Log-Change "Removed $hive Run\$name ($reason)"
    }
}

function Disable-StartupShortcut($linkPath, $reason) {
    if (-not (Test-Path $linkPath)) {
        Write-Host "Not found: $linkPath - skipping." -ForegroundColor DarkGray
        return
    }
    if ($WhatIf) {
        Log-Change "Would disable shortcut: $linkPath ($reason)"
    } else {
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        $dest = Join-Path $backupDir (Split-Path $linkPath -Leaf)
        Move-Item $linkPath $dest -Force
        Log-Change "Moved shortcut to backup: $(Split-Path $linkPath -Leaf) ($reason)"
    }
}

Write-Host "`n=== Startup Cleanup ===" -ForegroundColor Cyan
Write-Host "Safe tier: Adobe sync, Edge auto-launch, Jitsi Meet shortcut`n"

# Safe tier - low risk for dev workflow
Remove-RunKey "HKCU" "Adobe Acrobat Synchronizer" "background PDF sync, not needed at boot"
Remove-RunKey "HKCU" "MicrosoftEdgeAutoLaunch_0486D0EB8A82E7F344AAC35054CC22CD" "Edge background launch"

$jitsi = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\Jitsi Meet.lnk"
Disable-StartupShortcut $jitsi "video app; launch manually when needed"

if ($IncludeOptional) {
    Write-Host "`nOptional tier enabled.`n" -ForegroundColor Cyan
    Remove-RunKey "HKCU" "Teams" "Teams can be opened manually"
    Remove-RunKey "HKLM" "MuseHub" "music hub; open manually when needed"
}

Write-Host "`nKept (not disabled):" -ForegroundColor DarkGray
Write-Host "  OneDrive, Proton VPN, SecurityHealth, Realtek audio, deviceTRUST (Citrix)"
Write-Host "  Use -IncludeOptional to also disable Teams and MuseHub."

if (-not $WhatIf -and $changes.Count -gt 0) {
    Write-Host "`nBackup saved to: $backupDir" -ForegroundColor Cyan
}
Write-Host "`nDone. $($changes.Count) change(s) $(if ($WhatIf) { 'planned' } else { 'applied' })." -ForegroundColor Cyan