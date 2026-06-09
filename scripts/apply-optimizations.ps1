#Requires -Version 5.1
<#
.SYNOPSIS
  Apply safe, reversible optimizations for Grok Build on Windows.
.PARAMETER WhatIf
  Show planned changes without applying them.
.PARAMETER SkipDefender
  Skip Windows Defender exclusion changes.
.PARAMETER SkipPowerPlan
  Skip power plan change.
#>
param(
    [switch]$WhatIf,
    [switch]$SkipDefender,
    [switch]$SkipPowerPlan
)

$ErrorActionPreference = "Stop"
$grokHome = Join-Path $env:USERPROFILE ".grok"
$changes = [System.Collections.Generic.List[string]]::new()
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Log-Change($msg) {
    $changes.Add($msg)
    $prefix = if ($WhatIf) { "[WhatIf]" } else { "[Applied]" }
    Write-Host "$prefix $msg" -ForegroundColor $(if ($WhatIf) { "Yellow" } else { "Green" })
}

# --- Power plan: Balanced (better than Power Saver, less aggressive than High Performance) ---
if (-not $SkipPowerPlan) {
    if (-not $isAdmin) {
        Write-Host "Skipping power plan (requires admin). Re-run in elevated PowerShell." -ForegroundColor DarkYellow
    } else {
        $balancedGuid = "381b4222-f694-41f0-9685-ff5bb260df2e"
        $active = powercfg /GETACTIVESCHEME
        if ($active -match "Power saver|a1841308-3541-4fab-bc81-f71556f20b4a") {
            if ($WhatIf) {
                Log-Change "Would switch power plan from Power Saver to Balanced ($balancedGuid)"
            } else {
                powercfg /SETACTIVE $balancedGuid | Out-Null
                Log-Change "Switched power plan to Balanced"
            }
        } else {
            Write-Host "Power plan is not Power Saver - skipping." -ForegroundColor DarkGray
        }
    }
}

# --- User PATH: ensure grok bin is present ---
$grokBin = Join-Path $grokHome "bin"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$grokBin*") {
    $newPath = if ($userPath) { "$userPath;$grokBin" } else { $grokBin }
    if ($WhatIf) {
        Log-Change "Would append to User PATH: $grokBin"
    } else {
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$env:Path;$grokBin"
        Log-Change "Added $grokBin to User PATH (restart terminal to pick up everywhere)"
    }
} else {
    Write-Host "grok bin already on User PATH - skipping." -ForegroundColor DarkGray
}

# --- COLORTERM for Windows Terminal profiles via user env var ---
$colorTerm = [Environment]::GetEnvironmentVariable("COLORTERM", "User")
if ($colorTerm -ne "truecolor") {
    if ($WhatIf) {
        Log-Change "Would set User env COLORTERM=truecolor"
    } else {
        [Environment]::SetEnvironmentVariable("COLORTERM", "truecolor", "User")
        $env:COLORTERM = "truecolor"
        Log-Change "Set COLORTERM=truecolor (restart terminal)"
    }
}

# --- Merge recommended Grok config keys (non-destructive) ---
$recommended = Join-Path $PSScriptRoot "..\config\recommended-grok-config.toml"
$configPath = Join-Path $grokHome "config.toml"
if (Test-Path $recommended) {
    $recContent = Get-Content $recommended -Raw
    if (-not (Test-Path $configPath)) {
        if ($WhatIf) {
            Log-Change "Would create $configPath from recommended template"
        } else {
            Copy-Item $recommended $configPath
            Log-Change "Created config.toml from recommended template"
        }
    } else {
        $missing = @()
        foreach ($line in ($recContent -split "`n")) {
            if ($line -match '^\s*#' -or $line -match '^\s*$' -or $line -match '^\[') { continue }
            if ($line -match '^(\S+)\s*=') {
                $key = $Matches[1]
                $existing = Get-Content $configPath -Raw
                if ($existing -notmatch [regex]::Escape($key)) {
                    $missing += $line.Trim()
                }
            }
        }
        if ($missing.Count -gt 0) {
            $block = "`n# Added by grok-build-optimizer $(Get-Date -Format 'yyyy-MM-dd')`n" + ($missing -join "`n")
            if ($WhatIf) {
                Log-Change "Would append $($missing.Count) missing config keys to config.toml"
            } else {
                Add-Content -Path $configPath -Value $block -Encoding UTF8
                Log-Change "Appended $($missing.Count) missing config keys to config.toml"
            }
        } else {
            Write-Host "config.toml already contains recommended keys - skipping merge." -ForegroundColor DarkGray
        }
    }
}

# --- Defender exclusions (optional, reduces scan interference during builds) ---
if (-not $SkipDefender) {
    if (-not $isAdmin) {
        Write-Host "Skipping Defender exclusions (requires admin). Re-run in elevated PowerShell." -ForegroundColor DarkYellow
    } else {
        $exclusions = @(
            $grokHome,
            "C:\Projects",
            (Join-Path $env:LOCALAPPDATA "npm-cache"),
            (Join-Path $env:LOCALAPPDATA "pip\cache")
        )
        foreach ($path in $exclusions) {
            if (-not (Test-Path $path)) { continue }
            $existing = (Get-MpPreference).ExclusionPath
            if ($existing -notcontains $path) {
                if ($WhatIf) {
                    Log-Change "Would add Defender exclusion: $path"
                } else {
                    Add-MpPreference -ExclusionPath $path
                    Log-Change "Added Defender exclusion: $path"
                }
            }
        }
    }
}

Write-Host "`nDone. $($changes.Count) change(s) $(if ($WhatIf) { 'planned' } else { 'applied' })." -ForegroundColor Cyan
if (-not $WhatIf -and $changes.Count -gt 0) {
    Write-Host "Restart your terminal and run: grok" -ForegroundColor Cyan
    Write-Host "Then inside Grok run: /terminal-setup" -ForegroundColor Cyan
}