#Requires -Version 5.1
<#
.SYNOPSIS
  Run after reboot to finish WSL setup and install Ubuntu.
#>
param(
    [string]$Distro = "Ubuntu",
    [switch]$WhatIf
)

$ErrorActionPreference = "Continue"
Write-Host "=== WSL Post-Reboot Setup ===" -ForegroundColor Cyan

$virt = Get-CimInstance Win32_ComputerSystem | Select-Object -ExpandProperty HypervisorPresent
Write-Host "Hypervisor present: $virt"
if (-not $virt) {
    Write-Host @"

[WARN] Virtualization is not enabled in BIOS/UEFI.
Enable AMD-V / SVM Mode in your motherboard firmware, then reboot again.
Typical path: Restart -> BIOS -> Advanced -> CPU Configuration -> SVM Mode -> Enabled

"@ -ForegroundColor Yellow
}

$status = wsl --status 2>&1 | Out-String
Write-Host $status

$distros = wsl -l -q 2>&1 | Out-String
if ($distros -match $Distro) {
    Write-Host "$Distro already installed." -ForegroundColor Green
} elseif ($WhatIf) {
    Write-Host "[WhatIf] Would run: wsl --install -d $Distro" -ForegroundColor Yellow
} else {
    Write-Host "Installing $Distro..."
    wsl --install -d $Distro --no-launch 2>&1
}

Write-Host "`nVerify with: wsl -l -v" -ForegroundColor Cyan