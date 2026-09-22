#Requires -Version 5.1
<#
.SYNOPSIS
  Audit and apply reversible Windows performance tweaks.
.PARAMETER Audit
  Report current vs target settings and exit.
.PARAMETER Apply
  Apply tweaks (safe set, plus extras if -Extras).
.PARAMETER Extras
  Also apply optional workstation tweaks (SysMain, hibernate off).
.PARAMETER Undo
  Restore the most recent optimize backup.
.PARAMETER WhatIf
  Preview without writing settings.
.PARAMETER Force
  Skip the YES confirmation prompt.
#>
[CmdletBinding()]
param(
    [switch]$Audit,
    [switch]$Apply,
    [switch]$Extras,
    [switch]$Undo,
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = "Continue"
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LogDir = Join-Path $script:RepoRoot "logs"
. (Join-Path $PSScriptRoot "power-plan.ps1")
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
$script:DryRun = [bool]$WhatIf
$script:Backup = [System.Collections.Generic.List[object]]::new()
$script:Applied = [System.Collections.Generic.List[string]]::new()
$script:Skipped = [System.Collections.Generic.List[string]]::new()
$script:RebootNeeded = $false

$script:UsbSubGuid = "2a737441-1930-4402-8d77-b2bebba308a3"
$script:UsbSuspendGuid = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"

function Write-Log {
    param([string]$Message, [string]$Color = "Gray")
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    $log = Join-Path $script:LogDir "optimize.log"
    Add-Content -LiteralPath $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message) -Encoding UTF8
    Write-Host $Message -ForegroundColor $Color
}

function Get-RegValue([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Name
}

function Test-RegValueEquals([string]$Path, [string]$Name, $Expected) {
    $v = Get-RegValue $Path $Name
    if ($null -eq $v) { return $false }
    return ([int64]$v -eq [int64]$Expected)
}

function Get-PowerCfgAc([string]$Sub, [string]$Setting) {
    try {
        $out = powercfg /QUERY SCHEME_CURRENT $Sub $Setting 2>$null | Out-String
        if ($out -match "Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)") {
            return [Convert]::ToInt32($Matches[1], 16)
        }
    } catch { }
    return $null
}

function Get-MinProcessorPct {
    $v = Get-PowerCfgAc "SUB_PROCESSOR" "PROCTHROTTLEMIN"
    if ($null -eq $v) { return $null }
    return $v
}

function Get-ActiveScheme {
    $line = (powercfg /GETACTIVESCHEME | Out-String)
    if ($line -match "Power Scheme GUID:\s*([0-9a-fA-F-]+)\s+\(([^)]+)\)") {
        return [pscustomobject]@{ Guid = $Matches[1]; Name = $Matches[2] }
    }
    return [pscustomobject]@{ Guid = ""; Name = $line.Trim() }
}

function Get-LastAccessMode {
    $out = (fsutil behavior query disablelastaccess 2>$null | Out-String)
    if ($out -match "DisableLastAccess\s*=\s*(\d+)") { return [int]$Matches[1] }
    return $null
}

function New-Tweak {
    param(
        [string]$Id, [string]$Name, [bool]$NeedsAdmin, [bool]$Safe, [bool]$Extra,
        [bool]$Reboot, [string]$Current, [string]$Target, [bool]$Needed, [string]$Kind, [string]$Note
    )
    [pscustomobject]@{
        Id         = $Id
        Name       = $Name
        NeedsAdmin = $NeedsAdmin
        Safe       = $Safe
        Extra      = $Extra
        Reboot     = $Reboot
        Current    = $Current
        Target     = $Target
        Needed     = $Needed
        Kind       = $Kind
        Note       = $Note
    }
}

function Get-OptimizeTweaks {
    $scheme = Get-ActiveScheme
    $minCpu = Get-MinProcessorPct
    $powerOk = ($scheme.Guid -eq $script:HighPerfGuid -or $scheme.Name -match "High performance") -and ($minCpu -eq 100)
    $powerCurrent = if ($minCpu -ne $null) {
        "{0}, min CPU {1}%" -f $scheme.Name, $minCpu
    } else { $scheme.Name }

    $hags = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode"
    $dvr = Get-RegValue "HKCU:\System\GameConfigStore" "GameDVR_Enabled"
    $capture = Get-RegValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled"
    $gameMode = Get-RegValue "HKCU:\Software\Microsoft\GameBar" "AutoGameModeEnabled"
    $prio = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation"
    $hiberboot = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled"
    $lastAccess = Get-LastAccessMode
    $usb = Get-PowerCfgAc $script:UsbSubGuid $script:UsbSuspendGuid
    if ($null -eq $usb) { $usb = Get-PowerCfgAc "SUB_USB" "USBSELECTIVESUSPEND" }
    $aspm = Get-PowerCfgAc "SUB_PCIEXPRESS" "ASPM"
    $throttle = Get-RegValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "NetworkThrottlingIndex"
    $resp = Get-RegValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "SystemResponsiveness"
    $qos = Get-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched" "NonBestEffortLimit"
    $silentApps = Get-RegValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SilentInstalledAppsEnabled"
    $sysmain = Get-Service SysMain -ErrorAction SilentlyContinue
    $hiberOn = Test-Path -LiteralPath "C:\hiberfil.sys"
    $hiberSize = 0
    if ($hiberOn) {
        $hiberSize = (Get-Item -LiteralPath "C:\hiberfil.sys" -Force -ErrorAction SilentlyContinue).Length
    }
    $bgApps = Get-RegValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" "GlobalUserDisabled"

    $dvrOff = ($dvr -eq 0) -or (($null -eq $dvr) -and ($capture -eq 0))
    if ($null -eq $dvr -and $null -eq $capture) { $dvrOff = $false }

    $throttleOk = $null -ne $throttle -and ([uint32]$throttle -eq [uint32]4294967295)

    @(
        (New-Tweak -Id "power-plan" -Name "High Performance power plan" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current $powerCurrent -Target "High Performance, min CPU 100%" -Needed (-not $powerOk) `
            -Kind "setting" -Note "No core parking on this 16-core Ryzen")
        (New-Tweak -Id "gpu-scheduling" -Name "Hardware GPU scheduling" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $true `
            -Current $(if ($null -eq $hags) { "not set" } elseif ($hags -eq 2) { "on" } else { "off ($hags)" }) `
            -Target "on (HwSchMode=2)" -Needed ($hags -ne 2) `
            -Kind "setting" -Note "Lowers GPU submit latency on the RX 6900 XT")
        (New-Tweak -Id "game-dvr" -Name "Disable Xbox Game DVR capture" -NeedsAdmin $false -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($dvrOff) { "disabled" } else { "enabled" }) -Target "disabled" -Needed (-not $dvrOff) `
            -Kind "setting" -Note "Background recording steals GPU/CPU")
        (New-Tweak -Id "game-mode" -Name "Enable Game Mode" -NeedsAdmin $false -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($gameMode -eq 1) { "on" } else { "off/default" }) -Target "on" -Needed ($gameMode -ne 1) `
            -Kind "setting" -Note "Windows reduces background work in fullscreen apps")
        (New-Tweak -Id "foreground" -Name "Foreground app scheduling" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($null -eq $prio) { "missing" } elseif ($prio -eq 38) { "Programs (38)" } else { "$prio" }) `
            -Target "Programs (38)" -Needed ($prio -ne 38) `
            -Kind "setting" -Note "Same as System Properties > Adjust for best performance of programs")
        (New-Tweak -Id "fast-startup" -Name "Disable Fast Startup" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($hiberboot -eq 0) { "disabled" } else { "enabled" }) -Target "disabled" -Needed ($hiberboot -ne 0) `
            -Kind "setting" -Note "Hybrid shutdown leaves stale device/WSL state on desktops")
        (New-Tweak -Id "last-access" -Name "NTFS last-access timestamps" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($null -eq $lastAccess) { "unknown" } else { "$lastAccess" }) -Target "1 (disabled)" `
            -Needed ($lastAccess -ne 1 -and $lastAccess -ne 3) `
            -Kind "setting" -Note "Stops extra SSD writes on the 980 PRO")
        (New-Tweak -Id "usb-suspend" -Name "USB selective suspend" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($null -eq $usb) { "unknown" } elseif ($usb -eq 0) { "off" } else { "on" }) -Target "off" `
            -Needed ($usb -ne 0) -Kind "setting" -Note "Prevents USB devices dropping on a desktop")
        (New-Tweak -Id "pcie-aspm" -Name "PCI Express link-state power saving" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($null -eq $aspm) { "unknown" } elseif ($aspm -eq 0) { "off" } else { "on ($aspm)" }) -Target "off" `
            -Needed ($aspm -ne 0) -Kind "setting" -Note "Keeps the GPU link from downclocking")
        (New-Tweak -Id "net-throttle" -Name "Multimedia network throttle" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($null -eq $throttle) { "default" } elseif ($throttleOk) { "disabled" } else { "$throttle" }) `
            -Target "disabled (0xFFFFFFFF)" -Needed (-not $throttleOk) `
            -Kind "setting" -Note "Stops Windows capping multimedia/network throughput")
        (New-Tweak -Id "sys-resp" -Name "Multimedia system responsiveness" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($null -eq $resp) { "default (20)" } else { "$resp" }) -Target "10" `
            -Needed ($resp -ne 10) -Kind "setting" -Note "Gives foreground apps more CPU vs reserved background")
        (New-Tweak -Id "qos" -Name "Reserved QoS bandwidth" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($null -eq $qos) { "default (~20%)" } else { "$qos%" }) -Target "0%" `
            -Needed ($qos -ne 0) -Kind "setting" -Note "Windows can reserve ~20% of NIC bandwidth for QoS")
        (New-Tweak -Id "suggested-apps" -Name "Silent suggested-app installs" -NeedsAdmin $false -Safe $true -Extra $false -Reboot $false `
            -Current $(if ($silentApps -eq 0) { "disabled" } else { "enabled" }) -Target "disabled" `
            -Needed ($silentApps -ne 0) -Kind "setting" -Note "Stops Windows installing Store suggestions")
        (New-Tweak -Id "trim" -Name "TRIM NVMe SSD (C:)" -NeedsAdmin $true -Safe $true -Extra $false -Reboot $false `
            -Current "maintenance" -Target "run ReTrim" -Needed $true `
            -Kind "maintenance" -Note "Samsung 980 PRO — tells the SSD which blocks are free")
        (New-Tweak -Id "dns-flush" -Name "Flush DNS cache" -NeedsAdmin $false -Safe $true -Extra $false -Reboot $false `
            -Current "maintenance" -Target "ipconfig /flushdns" -Needed $true `
            -Kind "maintenance" -Note "Clears stale lookups")
        (New-Tweak -Id "sysmain" -Name "Disable SysMain (Superfetch)" -NeedsAdmin $true -Safe $false -Extra $true -Reboot $false `
            -Current $(if ($null -eq $sysmain) { "missing" } else { "$($sysmain.Status)/$($sysmain.StartType)" }) `
            -Target "Disabled/Stopped" `
            -Needed ($null -ne $sysmain -and -not ($sysmain.StartType -eq "Disabled")) `
            -Kind "setting" -Note "Optional on NVMe with 32 GB RAM — reduces background prefetch")
        (New-Tweak -Id "hibernate" -Name "Disable hibernate" -NeedsAdmin $true -Safe $false -Extra $true -Reboot $false `
            -Current $(if ($hiberOn) { "on ({0:N2} GB file)" -f ($hiberSize / 1GB) } else { "off" }) `
            -Target "off (delete hiberfil.sys)" -Needed $hiberOn `
            -Kind "setting" -Note "Desktop does not need hibernate; also turns off Fast Startup")
        (New-Tweak -Id "bg-apps" -Name "Restrict background Store apps" -NeedsAdmin $false -Safe $false -Extra $true -Reboot $false `
            -Current $(if ($bgApps -eq 1) { "restricted" } else { "allowed" }) -Target "restricted" `
            -Needed ($bgApps -ne 1) -Kind "setting" -Note "Stops UWP apps running in the background")
    )
}

function Add-Backup($entry) {
    $script:Backup.Add([pscustomobject]$entry)
}

function Set-RegDword {
    param([string]$Path, [string]$Name, [int64]$Value)
    $old = Get-RegValue $Path $Name
    $existed = $null -ne $old
    Add-Backup @{ Kind = "registry"; Path = $Path; Name = $Name; Existed = $existed; Value = $old }
    if ($script:DryRun) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value ([int]$Value) -PropertyType DWord -Force | Out-Null
}

function Set-PowerSetting {
    param([string]$Sub, [string]$Setting, [int]$Value)
    $oldAc = Get-PowerCfgAc $Sub $Setting
    Add-Backup @{ Kind = "powercfg"; Sub = $Sub; Setting = $Setting; Value = $oldAc }
    if ($script:DryRun) { return }
    powercfg /SETACVALUEINDEX SCHEME_CURRENT $Sub $Setting $Value 2>$null | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT $Sub $Setting $Value 2>$null | Out-Null
    powercfg /SETACTIVE SCHEME_CURRENT 2>$null | Out-Null
}

function Save-Backup {
    if ($script:DryRun) { return $null }
    if ($script:Backup.Count -eq 0) { return $null }
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    $path = Join-Path $script:LogDir ("optimize-backup-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))
    $payload = [pscustomobject]@{
        Timestamp = (Get-Date).ToString("o")
        Changes   = @($script:Backup)
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-LatestBackup {
    if (-not (Test-Path $script:LogDir)) { return $null }
    Get-ChildItem -LiteralPath $script:LogDir -Filter "optimize-backup-*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Invoke-TweakApply($t) {
    if ($t.Kind -eq "setting" -and -not $t.Needed) {
        return
    }
    if ($t.NeedsAdmin -and -not $script:IsAdmin) {
        $script:Skipped.Add("$($t.Name) (needs administrator)")
        return
    }

    switch ($t.Id) {
        "power-plan" {
            $result = Set-HighPerformancePlan -WhatIf:$script:DryRun
            if (-not $script:DryRun) {
                Add-Backup @{ Kind = "note"; Text = "power-plan set to High Performance" }
            }
            foreach ($msg in $result.Messages) { $script:Applied.Add($msg) }
        }
        "gpu-scheduling" {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" 2
            $script:RebootNeeded = $true
            $script:Applied.Add("Hardware GPU scheduling on (reboot needed)")
        }
        "game-dvr" {
            Set-RegDword "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0
            $script:Applied.Add("Game DVR capture disabled")
        }
        "game-mode" {
            Set-RegDword "HKCU:\Software\Microsoft\GameBar" "AutoGameModeEnabled" 1
            Set-RegDword "HKCU:\Software\Microsoft\GameBar" "AllowAutoGameMode" 1
            $script:Applied.Add("Game Mode enabled")
        }
        "foreground" {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" 38
            $script:Applied.Add("Foreground scheduling = Programs")
        }
        "fast-startup" {
            Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0
            $script:Applied.Add("Fast Startup disabled")
        }
        "last-access" {
            $old = Get-LastAccessMode
            Add-Backup @{ Kind = "fsutil-lastaccess"; Value = $old }
            if (-not $script:DryRun) { fsutil behavior set disablelastaccess 1 | Out-Null }
            $script:Applied.Add("NTFS last-access timestamps disabled")
        }
        "usb-suspend" {
            Set-PowerSetting $script:UsbSubGuid $script:UsbSuspendGuid 0
            $script:Applied.Add("USB selective suspend off")
        }
        "pcie-aspm" {
            Set-PowerSetting "SUB_PCIEXPRESS" "ASPM" 0
            $script:Applied.Add("PCI Express ASPM off")
        }
        "net-throttle" {
            Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "NetworkThrottlingIndex" -1
            $script:Applied.Add("Multimedia network throttle disabled")
        }
        "sys-resp" {
            Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "SystemResponsiveness" 10
            $script:Applied.Add("System responsiveness = 10")
        }
        "qos" {
            Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched" "NonBestEffortLimit" 0
            $script:Applied.Add("QoS reserved bandwidth = 0%")
        }
        "suggested-apps" {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SilentInstalledAppsEnabled" 0
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SystemPaneSuggestionsEnabled" 0
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SoftLandingEnabled" 0
            $script:Applied.Add("Silent suggested-app installs disabled")
        }
        "trim" {
            if ($script:DryRun) { $script:Applied.Add("Would TRIM C:") ; return }
            Write-Host "  Running TRIM on C: (can take a minute)..." -ForegroundColor DarkGray
            Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue
            $script:Applied.Add("TRIM issued on C:")
        }
        "dns-flush" {
            if ($script:DryRun) { $script:Applied.Add("Would flush DNS") ; return }
            ipconfig /flushdns | Out-Null
            $script:Applied.Add("DNS cache flushed")
        }
        "sysmain" {
            $svc = Get-Service SysMain -ErrorAction SilentlyContinue
            if ($svc) {
                Add-Backup @{ Kind = "service"; Name = "SysMain"; StartType = "$($svc.StartType)"; Status = "$($svc.Status)" }
            }
            if (-not $script:DryRun) {
                Stop-Service SysMain -Force -ErrorAction SilentlyContinue
                Set-Service SysMain -StartupType Disabled -ErrorAction SilentlyContinue
            }
            $script:Applied.Add("SysMain disabled")
        }
        "hibernate" {
            $on = Test-Path -LiteralPath "C:\hiberfil.sys"
            Add-Backup @{ Kind = "hibernate"; Enabled = $on }
            if (-not $script:DryRun) { powercfg /hibernate off | Out-Null }
            $script:Applied.Add("Hibernate disabled (hiberfil.sys removed)")
        }
        "bg-apps" {
            Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" "GlobalUserDisabled" 1
            $script:Applied.Add("Background Store apps restricted")
        }
        default { $script:Skipped.Add("unknown tweak $($t.Id)") }
    }
}

function Show-HardwareBrief {
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $gpu = (Get-CimInstance Win32_VideoController | Select-Object -First 1).Name
    $disk = Get-PhysicalDisk | Where-Object { $_.BusType -eq "NVMe" -or $_.MediaType -eq "SSD" } | Select-Object -First 1
    $diskName = if ($disk) { "{0} ({1})" -f $disk.FriendlyName, $disk.MediaType } else { "unknown" }
    $hv = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    Write-Host "  $cpu"
    Write-Host "  $ram GB RAM   $gpu"
    Write-Host "  $diskName"
    if (-not $hv) {
        Write-Host "  BIOS SVM is off — WSL2 will not run until you enable it in firmware." -ForegroundColor Yellow
    }
    Write-Host ""
}

function Show-StartupBrief {
    Write-Host "  Startup items:" -ForegroundColor Cyan
    $items = @(Get-CimInstance Win32_StartupCommand | Select-Object Name, Command |
        Sort-Object Name -Unique)
    foreach ($i in $items) {
        Write-Host ("    {0,-28} {1}" -f $i.Name, $i.Command) -ForegroundColor DarkGray
    }
    Write-Host "  Left alone on purpose: OneDrive, SecurityHealth, Realtek, AMD audio/AUEP." -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-Audit {
    param([object[]]$Tweaks)
    Write-Host ""
    Write-Host "  Performance audit" -ForegroundColor Cyan
    Write-Host "  Real settings only — no registry cleaners or RAM boosters." -ForegroundColor DarkGray
    if ($script:IsAdmin) {
        Write-Host "  Running as administrator" -ForegroundColor Green
    } else {
        Write-Host "  Not admin — several tweaks will be skipped until you relaunch elevated" -ForegroundColor DarkYellow
    }
    Write-Host ""
    Show-HardwareBrief

    Write-Host ("  {0,-22} {1,-38} {2,-28} {3}" -f "Id", "Setting", "Current", "Status") -ForegroundColor Cyan
    Write-Host ("  {0,-22} {1,-38} {2,-28} {3}" -f "------", "-------", "-------", "------") -ForegroundColor DarkGray
    $need = 0
    foreach ($t in $Tweaks) {
        if ($t.Extra) { continue }
        $status = if ($t.Kind -eq "maintenance") { "run" } elseif ($t.Needed) { "NEEDED" } else { "OK" }
        if ($t.Needed -and $t.Kind -eq "setting") { $need++ }
        $color = switch ($status) {
            "OK" { "Green" }
            "NEEDED" { "Yellow" }
            default { "DarkGray" }
        }
        Write-Host ("  {0,-22} {1,-38} {2,-28} {3}" -f $t.Id, $t.Name, $t.Current, $status) -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "  Optional extras (menu X):" -ForegroundColor Cyan
    foreach ($t in $Tweaks | Where-Object { $_.Extra }) {
        $status = if ($t.Needed) { "available" } else { "OK" }
        $color = if ($t.Needed) { "Yellow" } else { "Green" }
        Write-Host ("  {0,-22} {1,-38} {2,-28} {3}" -f $t.Id, $t.Name, $t.Current, $status) -ForegroundColor $color
        if ($t.Note) { Write-Host ("    {0}" -f $t.Note) -ForegroundColor DarkGray }
    }
    Write-Host ""
    Show-StartupBrief
    Write-Host ("  Safe setting changes waiting: {0}" -f $need) -ForegroundColor $(if ($need -gt 0) { "Yellow" } else { "Green" })
    Write-Host ""
}

function Confirm-Go {
    if ($Force) { return $true }
    Write-Host "  Type YES to continue, anything else to cancel." -ForegroundColor Yellow
    $answer = Read-Host "  Confirm"
    return ($answer -eq "YES")
}

function Invoke-Apply {
    param([object[]]$Tweaks, [switch]$IncludeExtras)
    $selected = @($Tweaks | Where-Object { -not $_.Extra -or $IncludeExtras })
    Write-Host ""
    Write-Host "  Planned:" -ForegroundColor Cyan
    $count = 0
    foreach ($t in $selected) {
        if ($t.Kind -eq "setting" -and -not $t.Needed) { continue }
        if ($t.NeedsAdmin -and -not $script:IsAdmin) {
            Write-Host ("    skip {0} (needs administrator)" -f $t.Name) -ForegroundColor DarkYellow
            continue
        }
        $count++
        $tag = if ($t.Kind -eq "maintenance") { "run" } else { "set" }
        Write-Host ("    [{0}] {1,-38} {2} -> {3}" -f $tag, $t.Name, $t.Current, $t.Target)
    }
    if ($script:DryRun) { Write-Host "  DRY RUN — nothing will be written" -ForegroundColor Yellow }
    Write-Host ""
    if ($count -eq 0) {
        Write-Host "  Nothing to do." -ForegroundColor Green
        return
    }
    if (-not $script:DryRun -and -not (Confirm-Go)) {
        Write-Host "  Cancelled." -ForegroundColor DarkYellow
        return
    }

    foreach ($t in $selected) {
        try { Invoke-TweakApply $t } catch {
            Write-Log ("  error in {0}: {1}" -f $t.Id, $_.Exception.Message) "Red"
        }
    }

    $backupPath = Save-Backup
    Write-Host ""
    $label = if ($script:DryRun) { "Would apply" } else { "Applied" }
    foreach ($line in $script:Applied) { Write-Host "  $label : $line" -ForegroundColor Green }
    foreach ($line in $script:Skipped) { Write-Host "  skip   : $line" -ForegroundColor DarkGray }
    if ($backupPath) {
        Write-Host "  Backup: $backupPath" -ForegroundColor DarkGray
        Write-Host "  Undo with: .\optimize.ps1 -Undo" -ForegroundColor DarkGray
    }
    if ($script:RebootNeeded) {
        Write-Host "  Reboot required for hardware GPU scheduling." -ForegroundColor Yellow
    }
    Write-Host ""
}

function Invoke-Undo {
    $file = Get-LatestBackup
    if (-not $file) {
        Write-Host "  No optimize backup found in logs\." -ForegroundColor Yellow
        return
    }
    Write-Host ("  Restore {0} ?" -f $file.Name) -ForegroundColor Cyan
    if (-not $script:DryRun -and -not (Confirm-Go)) {
        Write-Host "  Cancelled." -ForegroundColor DarkYellow
        return
    }
    $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $changes = @($data.Changes)
    [array]::Reverse($changes)
    foreach ($c in $changes) {
        try {
            switch ($c.Kind) {
                "registry" {
                    if ($script:DryRun) { Write-Host "  would restore $($c.Path)\$($c.Name)" -ForegroundColor Yellow; continue }
                    if ($c.Existed) {
                        if (-not (Test-Path -LiteralPath $c.Path)) { New-Item -Path $c.Path -Force | Out-Null }
                        New-ItemProperty -LiteralPath $c.Path -Name $c.Name -Value $c.Value -PropertyType DWord -Force | Out-Null
                    } else {
                        Remove-ItemProperty -LiteralPath $c.Path -Name $c.Name -ErrorAction SilentlyContinue
                    }
                    Write-Host "  restored $($c.Name)" -ForegroundColor Green
                }
                "powercfg" {
                    if ($null -eq $c.Value) { continue }
                    if ($script:DryRun) { Write-Host "  would restore powercfg $($c.Sub) $($c.Setting)" -ForegroundColor Yellow; continue }
                    powercfg /SETACVALUEINDEX SCHEME_CURRENT $c.Sub $c.Setting ([int]$c.Value) 2>$null | Out-Null
                    powercfg /SETDCVALUEINDEX SCHEME_CURRENT $c.Sub $c.Setting ([int]$c.Value) 2>$null | Out-Null
                    powercfg /SETACTIVE SCHEME_CURRENT 2>$null | Out-Null
                    Write-Host "  restored powercfg $($c.Setting)" -ForegroundColor Green
                }
                "service" {
                    if ($script:DryRun) { Write-Host "  would restore service $($c.Name)" -ForegroundColor Yellow; continue }
                    Set-Service -Name $c.Name -StartupType $c.StartType -ErrorAction SilentlyContinue
                    if ($c.Status -eq "Running") { Start-Service $c.Name -ErrorAction SilentlyContinue }
                    Write-Host "  restored service $($c.Name)" -ForegroundColor Green
                }
                "fsutil-lastaccess" {
                    if ($null -eq $c.Value) { continue }
                    if ($script:DryRun) { Write-Host "  would restore last-access $($c.Value)" -ForegroundColor Yellow; continue }
                    fsutil behavior set disablelastaccess $c.Value | Out-Null
                    Write-Host "  restored last-access mode $($c.Value)" -ForegroundColor Green
                }
                "hibernate" {
                    if ($c.Enabled) {
                        if ($script:DryRun) { Write-Host "  would re-enable hibernate" -ForegroundColor Yellow; continue }
                        powercfg /hibernate on | Out-Null
                        Write-Host "  hibernate re-enabled" -ForegroundColor Green
                    }
                }
            }
        } catch {
            Write-Host "  undo failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ""
}

# --- main when run directly ---
$calledDirectly = $MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s+'
if ($calledDirectly) {
    if (-not $Audit -and -not $Apply -and -not $Undo) { $Audit = $true }
    $tweaks = Get-OptimizeTweaks
    if ($Undo) { Invoke-Undo; return }
    if ($Audit -and -not $Apply) { Invoke-Audit -Tweaks $tweaks; return }
    if ($Apply) {
        Invoke-Audit -Tweaks $tweaks
        Invoke-Apply -Tweaks $tweaks -IncludeExtras:$Extras
    }
}
