#Requires -Version 5.1
<#
.SYNOPSIS
  Install WSL and Rust for Grok Build development.
.PARAMETER SkipWsl
  Skip WSL installation.
.PARAMETER SkipRust
  Skip Rust installation.
.PARAMETER WhatIf
  Preview actions only.
#>
param(
    [switch]$SkipWsl,
    [switch]$SkipRust,
    [switch]$WhatIf
)

$ErrorActionPreference = "Continue"
$log = Join-Path $PSScriptRoot "..\reports\dev-tools-setup.log"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Log($msg) {
    $line = "$(Get-Date -Format o) $msg"
    Add-Content -Path $log -Value $line
    Write-Host $msg
}

New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
"=== Dev tools setup $(Get-Date -Format o) ===" | Set-Content $log

# --- WSL ---
if (-not $SkipWsl) {
    $wslStatus = wsl --status 2>&1 | Out-String
    if ($wslStatus -match "not installed") {
        if (-not $isAdmin) {
            Log "WSL not installed. Run this script elevated or: wsl --install --no-distribution"
        } elseif ($WhatIf) {
            Log "[WhatIf] Would run: wsl --install --no-distribution"
        } else {
            Log "Installing WSL (no distro yet - avoids first-boot prompt)..."
            wsl --install --no-distribution 2>&1 | ForEach-Object { Log $_ }
            Log "WSL install initiated. A reboot may be required."
        }
    } else {
        Log "WSL already installed."
        wsl -l -v 2>&1 | ForEach-Object { Log $_ }
    }
}

# --- Rust ---
if (-not $SkipRust) {
    if (Get-Command rustc -ErrorAction SilentlyContinue) {
        Log "Rust already installed: $(rustc --version 2>&1)"
    } elseif ($WhatIf) {
        Log "[WhatIf] Would install Rust via winget: Rustlang.Rustup"
    } else {
        Log "Installing Rust via winget..."
        winget install Rustlang.Rustup --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object { Log $_ }

        $cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
        if (Test-Path (Join-Path $cargoBin "rustup.exe")) {
            Log "Setting default Rust toolchain to stable..."
            & (Join-Path $cargoBin "rustup.exe") default stable 2>&1 | ForEach-Object { Log $_ }
        }

        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$cargoBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$cargoBin", "User")
            Log "Added $cargoBin to User PATH"
        }

        if (Test-Path (Join-Path $cargoBin "rustc.exe")) {
            Log "Rust installed: $(& (Join-Path $cargoBin 'rustc.exe') --version 2>&1)"
        } else {
            Log "Rust install started - restart terminal and run: rustup default stable"
        }
    }
}

Log "DONE"