#Requires -Version 5.1
<#
.SYNOPSIS
  Enable Windows-side virtualization prerequisites for WSL2.
  NOTE: AMD-V / SVM must still be enabled in BIOS firmware.
#>
param([switch]$WhatIf)

$ErrorActionPreference = "Continue"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host "=== Virtualization Setup ===" -ForegroundColor Cyan

$sysinfo = systeminfo | Out-String
if ($sysinfo -match "Virtualization Enabled In Firmware:\s+Yes") {
    Write-Host "[OK] Virtualization enabled in firmware." -ForegroundColor Green
} else {
    Write-Host "[BLOCKED] Virtualization is OFF in BIOS/UEFI firmware." -ForegroundColor Red
    Write-Host @"

Enable AMD-V (SVM Mode) before WSL2 can run:

  1. Restart PC and press DEL or F2 during boot to enter BIOS
  2. Go to: Advanced -> CPU Configuration (or AMD CBS)
  3. Set SVM Mode (or AMD-V) -> Enabled
  4. Save and exit (F10)

Your board: ASUS/AMI BIOS (American Megatrends 4702, Oct 2023)
Common ASUS path: Advanced -> AMD CBS -> CPU Common Options -> SVM Mode

"@ -ForegroundColor Yellow
}

if (-not $isAdmin) {
    Write-Host "Run elevated to enable Windows features and hypervisor launch type." -ForegroundColor DarkYellow
    exit 1
}

$features = @(
    "Microsoft-Windows-Subsystem-Linux",
    "VirtualMachinePlatform",
    "HypervisorPlatform"
)

foreach ($feature in $features) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue).State
    Write-Host "Feature $feature : $state"
    if ($state -ne "Enabled" -and -not $WhatIf) {
        Write-Host "  Enabling $feature..."
        Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
    }
}

if ($WhatIf) {
    Write-Host "[WhatIf] Would set hypervisorlaunchtype auto via bcdedit"
} else {
    bcdedit /set hypervisorlaunchtype auto 2>&1 | Write-Host
    Write-Host "Set hypervisorlaunchtype=auto"
}

Write-Host "`nAfter enabling SVM in BIOS, reboot and run:" -ForegroundColor Cyan
Write-Host "  .\scripts\setup-wsl-post-reboot.ps1"