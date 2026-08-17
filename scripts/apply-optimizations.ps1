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
.PARAMETER HighPerformance
  Switch to High Performance power plan and set minimum CPU to 100% (no core parking).
#>
param(
    [switch]$WhatIf,
    [switch]$SkipDefender,
    [switch]$SkipPowerPlan,
    [switch]$HighPerformance
)

$ErrorActionPreference = "Stop"
$grokHome = Join-Path $env:USERPROFILE ".grok"
$changes = [System.Collections.Generic.List[string]]::new()
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$balancedGuid = "381b4222-f694-41f0-9685-ff5bb260df2e"
$highPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
$powerSaverGuid = "a1841308-3541-4fab-bc81-f71556f20b4a"

function Log-Change($msg) {
    $changes.Add($msg)
    $prefix = if ($WhatIf) { "[WhatIf]" } else { "[Applied]" }
    Write-Host "$prefix $msg" -ForegroundColor $(if ($WhatIf) { "Yellow" } else { "Green" })
}

function Get-TomlSections {
    param([string]$Content)
    $sections = [ordered]@{}
    $current = ""
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $current = $Matches[1]
            if (-not $sections.Contains($current)) {
                $sections[$current] = [System.Collections.Generic.List[string]]::new()
            }
            continue
        }
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\s*(\S+)\s*=') {
            if (-not $sections.Contains($current)) {
                $sections[$current] = [System.Collections.Generic.List[string]]::new()
            }
            $sections[$current].Add($line.TrimEnd())
        }
    }
    return $sections
}

function Merge-GrokConfig {
    param(
        [string]$ConfigPath,
        [string]$RecommendedPath
    )
    if (-not (Test-Path $RecommendedPath)) { return 0 }

    $recommended = Get-TomlSections (Get-Content $RecommendedPath -Raw)
    $existingContent = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw } else { "" }
    $existing = Get-TomlSections $existingContent

    $added = 0
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $ConfigPath) {
        foreach ($line in Get-Content $ConfigPath) { [void]$lines.Add($line) }
    }

    foreach ($section in $recommended.Keys) {
        $sectionKeys = @{}
        foreach ($entry in $recommended[$section]) {
            if ($entry -match '^\s*(\S+)\s*=') {
                $sectionKeys[$Matches[1]] = $entry
            }
        }

        $existingKeys = @{}
        if ($existing.Contains($section)) {
            foreach ($entry in $existing[$section]) {
                if ($entry -match '^\s*(\S+)\s*=') {
                    $existingKeys[$Matches[1]] = $true
                }
            }
        }

        $missing = @($sectionKeys.Keys | Where-Object { -not $existingKeys.ContainsKey($_) })
        if ($missing.Count -eq 0) { continue }

        if ($existing.Contains($section)) {
            $header = "[$section]"
            $idx = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*\[([^\]]+)\]\s*$' -and $Matches[1] -eq $section) {
                    $idx = $i
                    break
                }
            }
            if ($idx -ge 0) {
                $insertAt = $idx + 1
                while ($insertAt -lt $lines.Count -and $lines[$insertAt] -notmatch '^\s*\[') {
                    $insertAt++
                }
                $newLines = $missing | ForEach-Object { $sectionKeys[$_] }
                for ($j = $newLines.Count - 1; $j -ge 0; $j--) {
                    $lines.Insert($insertAt, $newLines[$j])
                }
                $added += $missing.Count
            }
        } else {
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -notmatch '^\s*$') {
                $lines.Add("")
            }
            $lines.Add("[$section]")
            foreach ($key in ($missing | Sort-Object)) {
                $lines.Add($sectionKeys[$key])
            }
            $added += $missing.Count
        }
    }

    # Remove root-level keys that belong in a named section (repair bad flat merges).
    $sectionedKeys = @{}
    foreach ($section in $recommended.Keys) {
        foreach ($entry in $recommended[$section]) {
            if ($entry -match '^\s*(\S+)\s*=') {
                $sectionedKeys[$Matches[1]] = $section
            }
        }
    }
    $currentSection = ""
    $removeAt = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $currentSection = $Matches[1]
            continue
        }
        if ($line -match '^\s*# Added by grok-build-optimizer') {
            $removeAt.Add($i)
            continue
        }
        if ($currentSection -eq "" -and $line -match '^\s*(\S+)\s*=') {
            if ($sectionedKeys.ContainsKey($Matches[1])) {
                $removeAt.Add($i)
            }
        }
    }
    $removed = $removeAt.Count
    foreach ($i in ($removeAt | Sort-Object -Descending)) {
        $lines.RemoveAt($i)
    }

    if ($added -gt 0 -or $removed -gt 0) {
        $text = ($lines -join "`n").TrimEnd() + "`n"
        if (-not $WhatIf) {
            Set-Content -Path $ConfigPath -Value $text -Encoding UTF8 -NoNewline
        }
    }
    return $added
}

# --- Power plan ---
if (-not $SkipPowerPlan) {
    if (-not $isAdmin) {
        Write-Host "Skipping power plan (requires admin). Re-run in elevated PowerShell." -ForegroundColor DarkYellow
    } elseif ($HighPerformance) {
        if ($WhatIf) {
            Log-Change "Would switch to High Performance power plan ($highPerfGuid)"
            Log-Change "Would set minimum processor state to 100% on AC and DC"
        } else {
            powercfg /SETACTIVE $highPerfGuid | Out-Null
            powercfg /SETACVALUEINDEX $highPerfGuid SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
            powercfg /SETDCVALUEINDEX $highPerfGuid SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
            powercfg /SETACTIVE $highPerfGuid | Out-Null
            Log-Change "Switched to High Performance power plan"
            Log-Change "Set minimum processor state to 100% (core parking disabled)"
        }
    } else {
        $active = powercfg /GETACTIVESCHEME
        if ($active -match "Power saver|$powerSaverGuid") {
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

# --- Merge recommended Grok config keys into correct sections ---
$recommended = Join-Path $PSScriptRoot "..\config\recommended-grok-config.toml"
$configPath = Join-Path $grokHome "config.toml"
if (Test-Path $recommended) {
    if (-not (Test-Path $configPath)) {
        if ($WhatIf) {
            Log-Change "Would create $configPath from recommended template"
        } else {
            Copy-Item $recommended $configPath
            Log-Change "Created config.toml from recommended template"
        }
    } else {
        $merged = Merge-GrokConfig -ConfigPath $configPath -RecommendedPath $recommended
        if ($merged -gt 0) {
            if ($WhatIf) {
                Log-Change "Would merge $merged missing config key(s) into correct sections"
            } else {
                Log-Change "Merged $merged missing config key(s) into correct sections"
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
if ($HighPerformance -and -not $isAdmin) {
    Write-Host "High Performance power plan requires admin. Re-run:" -ForegroundColor Yellow
    Write-Host "  .\scripts\run-admin-optimizations.bat" -ForegroundColor Yellow
    Write-Host "  or: Start-Process powershell -Verb RunAs -ArgumentList '-File apply-optimizations.ps1 -HighPerformance'" -ForegroundColor Yellow
}