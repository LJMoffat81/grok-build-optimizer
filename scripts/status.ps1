#Requires -Version 5.1
Write-Host "`n=== Grok Build Optimizer Status ===" -ForegroundColor Cyan

$checks = @()

# Power
$power = powercfg /GETACTIVESCHEME
$checks += [pscustomobject]@{ Check = "Power plan"; Status = if ($power -match "Balanced|High performance") { "OK" } else { "WARN" }; Detail = ($power -split "`n")[0] }

# Grok
$checks += [pscustomobject]@{ Check = "Grok"; Status = if (Get-Command grok -EA SilentlyContinue) { "OK" } else { "FAIL" }; Detail = (grok --version 2>&1) }

# Rust
$cargo = Join-Path $env:USERPROFILE ".cargo\bin\rustc.exe"
$checks += [pscustomobject]@{ Check = "Rust"; Status = if (Test-Path $cargo) { "OK" } else { "FAIL" }; Detail = if (Test-Path $cargo) { & $cargo --version 2>&1 } else { "not installed" } }

# COLORTERM
$ct = [Environment]::GetEnvironmentVariable("COLORTERM", "User")
$checks += [pscustomobject]@{ Check = "COLORTERM"; Status = if ($ct -eq "truecolor") { "OK" } else { "WARN" }; Detail = $ct }

# Virtualization
$fwLine = systeminfo | Select-String "Virtualization Enabled In Firmware"
$fw = if ($fwLine) { $fwLine.ToString().Trim() } else { "unknown" }
$hypervisor = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
$fwOk = $fw -match "Yes" -or $hypervisor
$checks += [pscustomobject]@{ Check = "BIOS virtualization"; Status = if ($fwOk) { "OK" } else { "BLOCKED" }; Detail = if ($fwLine) { $fw } else { "HypervisorPresent=$hypervisor" } }
$checks += [pscustomobject]@{ Check = "Hypervisor running"; Status = if ($hypervisor) { "OK" } else { "BLOCKED" }; Detail = "HypervisorPresent=$hypervisor" }

# WSL
$wslNames = @(wsl -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*$' })
$hasUbuntu = $wslNames -contains "Ubuntu" -or ($wslNames | Where-Object { $_ -like "Ubuntu*" }).Count -gt 0
$wslDetail = if ($hasUbuntu) { ($wslNames -join ", ") + " (WSL2)" } elseif (-not $hypervisor) { "needs BIOS SVM" } else { "run setup-wsl-post-reboot.ps1" }
$checks += [pscustomobject]@{ Check = "WSL distro"; Status = if ($hasUbuntu) { "OK" } elseif (-not $hypervisor) { "BLOCKED" } else { "PENDING" }; Detail = $wslDetail }

# Startup count
$startupCount = (Get-CimInstance Win32_StartupCommand).Count
$checks += [pscustomobject]@{ Check = "Startup programs"; Status = if ($startupCount -le 8) { "OK" } else { "WARN" }; Detail = "$startupCount items" }

$checks | Format-Table -AutoSize

$blocked = $checks | Where-Object Status -eq "BLOCKED"
if ($blocked) {
    Write-Host "Action required: Enable SVM Mode in BIOS (ASUS ROG CROSSHAIR VIII IMPACT)" -ForegroundColor Yellow
    Write-Host "  Advanced -> CPU Configuration -> SVM Mode -> Enabled -> F10 save -> reboot" -ForegroundColor Yellow
    Write-Host "  Then: .\scripts\setup-wsl-post-reboot.ps1`n" -ForegroundColor Cyan
}