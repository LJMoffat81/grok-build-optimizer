#Requires -Version 5.1
<#
.SYNOPSIS
  Clean junk and apply reversible Windows performance tweaks.
.DESCRIPTION
  Preview-first cleaner and optimizer. Default is an interactive menu.
  Safe categories never touch Documents, Pictures, Desktop, or project folders.
.PARAMETER Scan
  Print a junk size report and exit.
.PARAMETER Clean
  Clean selected categories (safe ones if -Categories is omitted).
.PARAMETER Audit
  Print a performance audit and exit.
.PARAMETER Optimize
  Apply safe performance tweaks (plus extras if -Extras).
.PARAMETER Extras
  With -Optimize, also apply optional workstation tweaks.
.PARAMETER Undo
  Restore the most recent optimization backup.
.PARAMETER WhatIf
  Preview without deleting or writing settings.
.PARAMETER Force
  Skip the YES confirmation prompt.
.PARAMETER Categories
  Category ids to clean: temp, windows-temp, crash-dumps, thumbnails,
  recycle, edge-cache, chrome-cache, pip, npm, cargo, gpu-cache,
  error-reports, home-node-modules, downloads-dupes, old-installers.
.EXAMPLE
  .\pc-cleanup.ps1
  .\pc-cleanup.ps1 -Scan
  .\pc-cleanup.ps1 -Clean -WhatIf
  .\pc-cleanup.ps1 -Audit
  .\pc-cleanup.ps1 -Optimize -WhatIf
  .\pc-cleanup.ps1 -Optimize -Extras
#>
[CmdletBinding()]
param(
    [switch]$Scan,
    [switch]$Clean,
    [switch]$Audit,
    [switch]$Optimize,
    [switch]$Extras,
    [switch]$Undo,
    [switch]$WhatIf,
    [switch]$Force,
    [string[]]$Categories
)

$ErrorActionPreference = "Continue"
$script:ScriptDir = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LogDir = Join-Path $script:RepoRoot "logs"
$script:LogPath = Join-Path $script:LogDir ("cleanup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
$script:DeletedBytes = [int64]0
$script:DeletedItems = 0
$script:FailedItems = 0
$script:SkippedLocked = 0
$script:DryRun = [bool]$WhatIf
$script:TempGrace = (Get-Date).AddMinutes(-15)

function Write-Log {
    param([string]$Message, [string]$Color = "Gray")
    $line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $Message
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    Write-Host $Message -ForegroundColor $Color
}

function Format-Size([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DriveLine {
    $c = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if (-not $c) { return "C: (unknown)" }
    return ("C: {0} used  {1} free  of {2}" -f
        (Format-Size ([int64]$c.Used)),
        (Format-Size ([int64]$c.Free)),
        (Format-Size ([int64]($c.Used + $c.Free))))
}

function Get-TreeSize([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return [int64]0 }
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return [int64]0 }
    if (-not $item.PSIsContainer) { return [int64]$item.Length }
    $sum = [int64]0
    try {
        $opts = [System.IO.EnumerationOptions]::new()
        $opts.RecurseSubdirectories = $true
        $opts.IgnoreInaccessible = $true
        $opts.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Path, "*", $opts)) {
            try { $sum += ([System.IO.FileInfo]$f).Length } catch { }
        }
        return $sum
    } catch { }
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object { $sum += $_.Length }
    } catch { }
    return $sum
}

function Measure-Paths([string[]]$Paths) {
    $sum = [int64]0
    foreach ($p in @($Paths)) {
        if ($p) { $sum += Get-TreeSize $p }
    }
    return $sum
}

function Get-RecycleBinSize {
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.NameSpace(0xA)
        if (-not $bin) { return @{ Bytes = [int64]0; Count = 0 } }
        $items = @($bin.Items())
        $bytes = [int64]0
        foreach ($item in $items) {
            try { $bytes += [int64]$item.Size } catch { }
        }
        return @{ Bytes = $bytes; Count = $items.Count }
    } catch {
        return @{ Bytes = [int64]0; Count = 0 }
    }
}

function Get-DownloadsDupes {
    $downloads = Join-Path $env:USERPROFILE "Downloads"
    $pairs = @()
    if (-not (Test-Path -LiteralPath $downloads)) { return $pairs }
    $archives = Get-ChildItem -LiteralPath $downloads -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in ".zip", ".7z", ".rar" }
    foreach ($archive in $archives) {
        $folder = Join-Path $downloads $archive.BaseName
        if (Test-Path -LiteralPath $folder) {
            $folderSize = Get-TreeSize $folder
            $pairs += [pscustomobject]@{
                Archive     = $archive.FullName
                ArchiveSize = [int64]$archive.Length
                Folder      = $folder
                FolderSize  = [int64]$folderSize
                Total       = [int64]($archive.Length + $folderSize)
            }
        }
    }
    return @($pairs)
}

function Get-OldInstallers {
    $downloads = Join-Path $env:USERPROFILE "Downloads"
    if (-not (Test-Path -LiteralPath $downloads)) { return @() }
    $cutoff = (Get-Date).AddDays(-30)
    @(Get-ChildItem -LiteralPath $downloads -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -in ".exe", ".msi", ".msix", ".iso" -and
            $_.LastWriteTime -lt $cutoff -and
            $_.Length -ge 5MB
        })
}

function Get-ExistingPaths([string[]]$Paths) {
    @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

function Get-EdgeCachePaths {
    $root = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
    Get-BrowserCachePaths $root
}

function Get-ChromeCachePaths {
    $root = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    Get-BrowserCachePaths $root
}

function Get-BrowserCachePaths([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $names = @("Cache", "Code Cache", "GPUCache", "Service Worker\CacheStorage", "ShaderCache")
    $paths = @()
    Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($n in $names) {
            $p = Join-Path $_.FullName $n
            if (Test-Path -LiteralPath $p) { $paths += $p }
        }
    }
    return $paths
}

function Get-GpuCachePaths {
    Get-ExistingPaths @(
        (Join-Path $env:LOCALAPPDATA "D3DSCache"),
        (Join-Path $env:LOCALAPPDATA "AMD\DxCache"),
        (Join-Path $env:LOCALAPPDATA "AMD\VkCache"),
        (Join-Path $env:LOCALAPPDATA "NVIDIA\DXCache"),
        (Join-Path $env:LOCALAPPDATA "NVIDIA\GLCache")
    )
}

function Remove-One {
    param(
        [string]$Path,
        [switch]$Recurse,
        [Nullable[datetime]]$SkipNewerThan
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if ($null -ne $SkipNewerThan -and $item.LastWriteTime -gt $SkipNewerThan) {
        return
    }
    $size = [int64]0
    if ($item.PSIsContainer) { $size = Get-TreeSize $Path } else { $size = [int64]$item.Length }

    if ($script:DryRun) {
        $script:DeletedBytes += $size
        $script:DeletedItems++
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Force -Recurse:$Recurse -ErrorAction Stop
        $script:DeletedBytes += $size
        $script:DeletedItems++
    } catch {
        $script:SkippedLocked++
        $script:FailedItems++
        Write-Log "  skipped (in use): $Path" "DarkGray"
    }
}

function Clear-FolderContents {
    param(
        [string]$Path,
        [Nullable[datetime]]$SkipNewerThan
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-One -Path $_.FullName -Recurse -SkipNewerThan $SkipNewerThan
    }
}

function New-Category {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Note,
        [bool]$Safe,
        [bool]$NeedsAdmin,
        [string]$Action,
        [string[]]$Paths,
        [bool]$SkipRecent,
        $Extra,
        [int64]$Bytes = -1,
        [int]$RecycleCount = 0
    )
    $pathList = @($Paths)
    if ($Bytes -lt 0) {
        $Bytes = Measure-Paths $pathList
    }
    [pscustomobject]@{
        Id           = $Id
        Name         = $Name
        Note         = $Note
        Safe         = $Safe
        NeedsAdmin   = $NeedsAdmin
        Action       = $Action
        Paths        = $pathList
        SkipRecent   = $SkipRecent
        Extra        = $Extra
        Bytes        = [int64]$Bytes
        RecycleCount = $RecycleCount
    }
}

function Get-CategoryCatalog {
    $dupes = @(Get-DownloadsDupes)
    $installers = @(Get-OldInstallers)
    $recycle = Get-RecycleBinSize
    $dupeZipBytes = [int64]0
    foreach ($d in $dupes) { $dupeZipBytes += $d.ArchiveSize }
    $installerBytes = [int64]0
    foreach ($i in $installers) { $installerBytes += $i.Length }

    $thumbDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer"
    $thumbFiles = @()
    if (Test-Path -LiteralPath $thumbDir) {
        $thumbFiles = @(Get-ChildItem -LiteralPath $thumbDir -File -Filter "thumbcache_*.db" -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }

    $homeNm = Join-Path $env:USERPROFILE "node_modules"

    @(
        (New-Category -Id "temp" -Name "User temp files" -Safe $true -NeedsAdmin $false `
            -Note "Files in %TEMP% older than 15 minutes" `
            -Action "clear-contents" -SkipRecent $true -Paths @($env:TEMP))
        (New-Category -Id "windows-temp" -Name "Windows temp files" -Safe $true -NeedsAdmin $true `
            -Note "C:\Windows\Temp (needs Run as administrator)" `
            -Action "clear-contents" -SkipRecent $true -Paths @(Join-Path $env:WINDIR "Temp"))
        (New-Category -Id "crash-dumps" -Name "Crash dumps" -Safe $true -NeedsAdmin $false `
            -Note "App crash dumps in Local\CrashDumps" `
            -Action "clear-contents" -Paths @(Join-Path $env:LOCALAPPDATA "CrashDumps"))
        (New-Category -Id "thumbnails" -Name "Thumbnail cache" -Safe $true -NeedsAdmin $false `
            -Note "Explorer thumbnail databases (rebuild themselves)" `
            -Action "remove-files" -Paths $thumbFiles)
        (New-Category -Id "recycle" -Name "Recycle Bin" -Safe $true -NeedsAdmin $false `
            -Note ("{0} item(s)" -f $recycle.Count) `
            -Action "recycle" -Paths @() -Bytes $recycle.Bytes -RecycleCount $recycle.Count)
        (New-Category -Id "edge-cache" -Name "Microsoft Edge cache" -Safe $true -NeedsAdmin $false `
            -Note "Cache only — history and logins stay" `
            -Action "clear-contents" -Paths @(Get-EdgeCachePaths))
        (New-Category -Id "chrome-cache" -Name "Google Chrome cache" -Safe $true -NeedsAdmin $false `
            -Note "Cache only — skipped if Chrome is not installed" `
            -Action "clear-contents" -Paths @(Get-ChromeCachePaths))
        (New-Category -Id "pip" -Name "Python pip cache" -Safe $true -NeedsAdmin $false `
            -Note "Downloaded wheels; pip will re-fetch if needed" `
            -Action "pip" -Paths @(Join-Path $env:LOCALAPPDATA "pip\Cache"))
        (New-Category -Id "npm" -Name "npm cache" -Safe $true -NeedsAdmin $false `
            -Note "Package tarballs; npm will re-fetch if needed" `
            -Action "npm" -Paths (Get-ExistingPaths @(
                (Join-Path $env:LOCALAPPDATA "npm-cache"),
                (Join-Path $env:APPDATA "npm-cache")
            )))
        (New-Category -Id "cargo" -Name "Rust cargo crate cache" -Safe $true -NeedsAdmin $false `
            -Note "registry/cache only — not your projects" `
            -Action "clear-contents" -Paths (Get-ExistingPaths @(
                (Join-Path $env:USERPROFILE ".cargo\registry\cache")
            )))
        (New-Category -Id "gpu-cache" -Name "GPU shader cache" -Safe $true -NeedsAdmin $false `
            -Note "AMD/NVIDIA/DirectX shader caches (rebuild on next game/app)" `
            -Action "clear-contents" -Paths @(Get-GpuCachePaths))
        (New-Category -Id "error-reports" -Name "Windows error reports" -Safe $true -NeedsAdmin $false `
            -Note "WER reports in your profile" `
            -Action "clear-contents" -Paths @(Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER"))
        (New-Category -Id "home-node-modules" -Name "Stray home node_modules" -Safe $true -NeedsAdmin $false `
            -Note "$homeNm leftover (not a project)" `
            -Action "remove-trees" -Paths @($homeNm))
        (New-Category -Id "downloads-dupes" -Name "Downloads: zip + extracted folder" -Safe $false -NeedsAdmin $false `
            -Note ("{0} pair(s) — deletes the ZIP, keeps the folder" -f $dupes.Count) `
            -Action "remove-files" -Paths @($dupes | ForEach-Object { $_.Archive }) `
            -Bytes $dupeZipBytes -Extra $dupes)
        (New-Category -Id "old-installers" -Name "Downloads: old installers (30+ days)" -Safe $false -NeedsAdmin $false `
            -Note ("{0} file(s) over 5 MB" -f $installers.Count) `
            -Action "remove-files" -Paths @($installers | ForEach-Object { $_.FullName }) `
            -Bytes $installerBytes -Extra $installers)
    )
}

function Invoke-CategoryClean($cat) {
    $skip = $null
    if ($cat.SkipRecent) { $skip = $script:TempGrace }

    switch ($cat.Action) {
        "recycle" {
            if ($script:DryRun) {
                $script:DeletedBytes += $cat.Bytes
                $script:DeletedItems += $cat.RecycleCount
                return
            }
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            $script:DeletedBytes += $cat.Bytes
            $script:DeletedItems += $cat.RecycleCount
        }
        "pip" {
            if (-not $script:DryRun -and (Get-Command pip -ErrorAction SilentlyContinue)) {
                pip cache purge 2>$null | Out-Null
            }
            foreach ($p in $cat.Paths) { Clear-FolderContents -Path $p -SkipNewerThan $skip }
        }
        "npm" {
            if (-not $script:DryRun -and (Get-Command npm -ErrorAction SilentlyContinue)) {
                npm cache clean --force 2>$null | Out-Null
            }
            foreach ($p in $cat.Paths) { Clear-FolderContents -Path $p -SkipNewerThan $skip }
        }
        "clear-contents" {
            foreach ($p in $cat.Paths) { Clear-FolderContents -Path $p -SkipNewerThan $skip }
        }
        "remove-trees" {
            foreach ($p in $cat.Paths) { Remove-One -Path $p -Recurse }
        }
        "remove-files" {
            foreach ($p in $cat.Paths) { Remove-One -Path $p }
        }
        default {
            Write-Log ("  unknown action {0} for {1}" -f $cat.Action, $cat.Id) "Red"
        }
    }
}

function Invoke-Optimizer {
    param(
        [switch]$DoAudit,
        [switch]$DoApply,
        [switch]$DoUndo,
        [switch]$DoExtras
    )
    $opt = Join-Path $script:ScriptDir "optimize.ps1"
    if (-not (Test-Path -LiteralPath $opt)) {
        Write-Host "  optimize.ps1 not found next to this script." -ForegroundColor Red
        return
    }
    $whatIf = $script:DryRun -and -not $DoAudit
    if ($DoAudit) { & $opt -Audit; return }
    if ($DoUndo) {
        if ($whatIf) { & $opt -Undo -WhatIf } else { & $opt -Undo -Force:$Force }
        return
    }
    if ($DoApply) {
        if ($whatIf) {
            & $opt -Apply -WhatIf -Extras:$DoExtras
        } else {
            & $opt -Apply -Extras:$DoExtras -Force:$Force
        }
    }
}

function Start-ElevatedSelf {
    $target = $PSCommandPath
    $exe = (Get-Process -Id $PID).Path
    Write-Host "  Launching an administrator window..." -ForegroundColor Yellow
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $target
    )
}

function Show-Banner {
    Write-Host ""
    Write-Host "  PC Cleanup + Optimize" -ForegroundColor Cyan
    Write-Host "  Preview first. Documents, Pictures, Desktop, and project folders are never touched." -ForegroundColor DarkGray
    Write-Host "  $(Get-DriveLine)" -ForegroundColor DarkGray
    if ($script:IsAdmin) {
        Write-Host "  Running as administrator" -ForegroundColor Green
    } else {
        Write-Host "  Not admin — Windows\Temp will be skipped unless you re-run elevated" -ForegroundColor DarkYellow
    }
    if ($script:DryRun) {
        Write-Host "  DRY RUN — nothing will be deleted or changed" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Invoke-Scan {
    param([object[]]$Catalog)
    Write-Host ("  {0,-22} {1,-42} {2,12}  {3}" -f "Id", "Category", "Size", "Notes") -ForegroundColor Cyan
    Write-Host ("  {0,-22} {1,-42} {2,12}  {3}" -f "------", "--------", "----", "-----") -ForegroundColor DarkGray
    $total = [int64]0
    $safeTotal = [int64]0
    foreach ($cat in $Catalog) {
        $bytes = [int64]$cat.Bytes
        $total += $bytes
        if ($cat.Safe) { $safeTotal += $bytes }
        $mark = if ($cat.Safe) { "" } else { "*" }
        $color = if ($bytes -eq 0) { "DarkGray" } elseif ($cat.Safe) { "White" } else { "Yellow" }
        Write-Host ("  {0,-22} {1,-42} {2,12}  {3}" -f ($cat.Id + $mark), $cat.Name, (Format-Size $bytes), $cat.Note) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host ("  Safe to clean now:     {0}" -f (Format-Size $safeTotal)) -ForegroundColor Green
    Write-Host ("  Needs your review (*): {0}" -f (Format-Size ($total - $safeTotal))) -ForegroundColor Yellow
    Write-Host ("  Combined:              {0}" -f (Format-Size $total)) -ForegroundColor Cyan
    Write-Host ""

    $dupeCat = $Catalog | Where-Object { $_.Id -eq "downloads-dupes" } | Select-Object -First 1
    $dupes = @($dupeCat.Extra)
    if ($dupes.Count -gt 0) {
        Write-Host "  Duplicate archive + extracted folder in Downloads:" -ForegroundColor Yellow
        foreach ($d in $dupes) {
            Write-Host ("    ZIP    {0,-12}  {1}" -f (Format-Size $d.ArchiveSize), (Split-Path $d.Archive -Leaf))
            Write-Host ("    Folder {0,-12}  {1}" -f (Format-Size $d.FolderSize), (Split-Path $d.Folder -Leaf))
        }
        Write-Host "  Cleaning this category deletes the ZIP only and keeps the extracted folder." -ForegroundColor DarkGray
        Write-Host ""
    }

    $instCat = $Catalog | Where-Object { $_.Id -eq "old-installers" } | Select-Object -First 1
    $installers = @($instCat.Extra)
    if ($installers.Count -gt 0) {
        Write-Host "  Old installers in Downloads (30+ days, 5+ MB):" -ForegroundColor Yellow
        foreach ($i in $installers) {
            Write-Host ("    {0,-12}  {1}" -f (Format-Size $i.Length), $i.Name)
        }
        Write-Host ""
    }
}

function Confirm-Clean {
    if ($Force) { return $true }
    Write-Host "  Type YES to continue, anything else to cancel." -ForegroundColor Yellow
    $answer = Read-Host "  Confirm"
    return ($answer -eq "YES")
}

function Invoke-Clean {
    param(
        [object[]]$Catalog,
        [string[]]$Ids
    )
    $wanted = @($Catalog | Where-Object { $Ids -contains $_.Id })
    if ($wanted.Count -eq 0) {
        Write-Host "  No matching categories." -ForegroundColor Red
        return
    }

    Write-Host "  Will process:" -ForegroundColor Cyan
    $preview = [int64]0
    $run = @()
    foreach ($cat in $wanted) {
        if ($cat.NeedsAdmin -and -not $script:IsAdmin) {
            Write-Host ("    skip {0} (needs administrator)" -f $cat.Name) -ForegroundColor DarkYellow
            continue
        }
        $preview += [int64]$cat.Bytes
        $run += $cat
        Write-Host ("    {0,-42} {1,12}" -f $cat.Name, (Format-Size $cat.Bytes))
    }
    Write-Host ("  About {0}{1}" -f (Format-Size $preview), $(if ($script:DryRun) { " (dry run)" } else { "" })) -ForegroundColor Cyan
    Write-Host ""

    if ($run.Count -eq 0) { return }

    if (-not $script:DryRun -and -not (Confirm-Clean)) {
        Write-Host "  Cancelled." -ForegroundColor DarkYellow
        return
    }

    $script:DeletedBytes = 0
    $script:DeletedItems = 0
    $script:FailedItems = 0
    $script:SkippedLocked = 0
    Write-Log ("Starting clean. DryRun={0}" -f $script:DryRun) "Gray"

    foreach ($cat in $run) {
        Write-Host ("  Cleaning {0}..." -f $cat.Name) -ForegroundColor Cyan
        try {
            Invoke-CategoryClean $cat
        } catch {
            Write-Log ("  error in {0}: {1}" -f $cat.Id, $_.Exception.Message) "Red"
        }
    }

    $label = if ($script:DryRun) { "Would free" } else { "Freed" }
    Write-Host ""
    Write-Host ("  {0}: {1}" -f $label, (Format-Size $script:DeletedBytes)) -ForegroundColor Green
    Write-Host ("  Items: {0}   Locked/skipped: {1}" -f $script:DeletedItems, $script:SkippedLocked) -ForegroundColor DarkGray
    if (-not $script:DryRun) {
        Write-Host ("  Log: {0}" -f $script:LogPath) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  $(Get-DriveLine)" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Menu {
    Write-Host "  Clean" -ForegroundColor Cyan
    Write-Host "  [1] Scan junk (no deletions)"
    Write-Host "  [2] Clean safe junk (temp, caches, recycle, dumps)"
    Write-Host "  [3] Clean developer caches (npm, pip, cargo, stray node_modules)"
    Write-Host "  [4] Clean browser caches (Edge / Chrome)"
    Write-Host "  [5] Remove duplicate ZIPs in Downloads (keeps extracted folders)"
    Write-Host "  [6] Remove old Downloads installers (30+ days)"
    Write-Host "  [7] Empty Recycle Bin"
    Write-Host "  [8] Full safe clean (2 + 3 + 4 + 7)"
    Write-Host ""
    Write-Host "  Optimize" -ForegroundColor Cyan
    Write-Host "  [9] Performance audit (no changes)"
    Write-Host "  [O] Apply safe optimizations"
    Write-Host "  [X] Apply extra workstation tweaks (SysMain, hibernate, background apps)"
    Write-Host "  [U] Undo last optimization run"
    Write-Host "  [A] Relaunch as administrator"
    Write-Host ""
    Write-Host "  [D] Toggle dry-run (currently: $($script:DryRun))"
    Write-Host "  [Q] Quit"
    Write-Host ""
}

# --- main ---
Show-Banner
$catalog = Get-CategoryCatalog

if ($Audit) {
    Invoke-Optimizer -DoAudit
    return
}

if ($Undo) {
    Invoke-Optimizer -DoUndo
    return
}

if ($Optimize) {
    Invoke-Optimizer -DoApply -DoExtras:$Extras
    return
}

if ($Scan) {
    Invoke-Scan -Catalog $catalog
    Write-Host "  Log folder: $script:LogDir" -ForegroundColor DarkGray
    return
}

if ($Clean) {
    $ids = $Categories
    if (-not $ids -or $ids.Count -eq 0) {
        $ids = @($catalog | Where-Object { $_.Safe } | ForEach-Object { $_.Id })
    }
    Invoke-Scan -Catalog $catalog
    Invoke-Clean -Catalog $catalog -Ids $ids
    return
}

while ($true) {
    Show-Menu
    $choice = (Read-Host "  Choose").Trim()
    switch -Regex ($choice) {
        "^(1|s)$" {
            $catalog = Get-CategoryCatalog
            Invoke-Scan -Catalog $catalog
        }
        "^2$" {
            $catalog = Get-CategoryCatalog
            Invoke-Clean -Catalog $catalog -Ids @("temp", "windows-temp", "crash-dumps", "thumbnails", "recycle", "gpu-cache", "error-reports")
        }
        "^3$" {
            $catalog = Get-CategoryCatalog
            Invoke-Clean -Catalog $catalog -Ids @("pip", "npm", "cargo", "home-node-modules")
        }
        "^4$" {
            $catalog = Get-CategoryCatalog
            Invoke-Clean -Catalog $catalog -Ids @("edge-cache", "chrome-cache")
        }
        "^5$" {
            $catalog = Get-CategoryCatalog
            Invoke-Scan -Catalog $catalog
            Invoke-Clean -Catalog $catalog -Ids @("downloads-dupes")
        }
        "^6$" {
            $catalog = Get-CategoryCatalog
            Invoke-Scan -Catalog $catalog
            Invoke-Clean -Catalog $catalog -Ids @("old-installers")
        }
        "^7$" {
            $catalog = Get-CategoryCatalog
            Invoke-Clean -Catalog $catalog -Ids @("recycle")
        }
        "^8$" {
            $catalog = Get-CategoryCatalog
            $ids = @($catalog | Where-Object { $_.Safe } | ForEach-Object { $_.Id })
            Invoke-Clean -Catalog $catalog -Ids $ids
        }
        "^9$" {
            Invoke-Optimizer -DoAudit
        }
        "^(o|O)$" {
            Invoke-Optimizer -DoApply
        }
        "^(x|X)$" {
            Invoke-Optimizer -DoApply -DoExtras
        }
        "^(u|U)$" {
            Invoke-Optimizer -DoUndo
        }
        "^(a|A)$" {
            if ($script:IsAdmin) {
                Write-Host "  Already running as administrator." -ForegroundColor Green
                Write-Host ""
            } else {
                Start-ElevatedSelf
            }
        }
        "^(d|D)$" {
            $script:DryRun = -not $script:DryRun
            $state = if ($script:DryRun) { "ON — nothing will be deleted" } else { "OFF — deletions are live" }
            Write-Host "  Dry-run $state" -ForegroundColor Yellow
            Write-Host ""
        }
        "^(q|Q)$" { return }
        default {
            Write-Host "  Unknown choice." -ForegroundColor DarkYellow
            Write-Host ""
        }
    }
}
