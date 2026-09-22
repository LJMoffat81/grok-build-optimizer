# Shared High Performance power plan.
# Dot-source from apply-optimizations.ps1 and optimize.ps1.
# This file is the only place that switches the scheme and the minimum CPU.

$script:HighPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"

function Set-HighPerformancePlan {
    param([switch]$WhatIf)

    $guid = $script:HighPerfGuid
    if ($WhatIf) {
        return [pscustomobject]@{
            Applied  = $false
            Messages = @(
                "Would switch to High Performance power plan ($guid)",
                "Would set minimum processor state to 100% on AC and DC"
            )
        }
    }

    powercfg /SETACTIVE $guid | Out-Null
    powercfg /SETACVALUEINDEX $guid SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
    powercfg /SETDCVALUEINDEX $guid SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
    powercfg /SETACTIVE $guid | Out-Null
    return [pscustomobject]@{
        Applied  = $true
        Messages = @(
            "Switched to High Performance power plan",
            "Set minimum processor state to 100% (core parking disabled)"
        )
    }
}
