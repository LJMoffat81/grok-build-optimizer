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
$fw = (systeminfo | Select-String "Virtualization Enabled In Firmware").ToString().Trim()
$hypervisor = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
$checks += [pscustomobject]@{ Check = "BIOS virtualization"; Status = if ($fw -match "Yes") { "OK" } else { "BLOCKED" }; Detail = $fw }
$checks += [pscustomobject]@{ Check = "Hypervisor running"; Status = if ($hypervisor) { "OK" } else { "BLOCKED" }; Detail = "HypervisorPresent=$hypervisor" }

# WSL
$wslList = wsl -l -v 2>&1 | Out-String
$checks += [pscustomobject]@{ Check = "WSL distro"; Status = if ($wslList -match "Ubuntu") { "OK" } elseif ($fw -match "No") { "BLOCKED" } else { "PENDING" }; Detail = if ($wslList -match "Ubuntu") { "Ubuntu installed" } else { "needs BIOS SVM + reboot" } }

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