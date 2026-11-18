[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot
$ErrorActionPreference='Stop'

. (Join-Path $PSScriptRoot 'science-common.ps1')
. (Join-Path $PSScriptRoot 'science-release.ps1')
. (Join-Path $PSScriptRoot 'science-update.ps1')
. (Join-Path $PSScriptRoot 'science-root-removal.ps1')

try{
    if(-not (Test-ScienceInteractiveConfiguration)){throw 'Whole-root removal requires an interactive console.'}
    $inventory=Get-ScienceCleanupInventory $ScienceRelease.MicromambaSha256
    if(-not $inventory.Roots.Count){Write-Host 'No Micromamba roots detected.';exit 0}
    $selection=Select-ScienceTotalRoot $inventory
    if(-not $selection){Write-Host 'Cancelled. Nothing was removed.';exit 0}
    $row=$selection.Row
    $plan=Get-ScienceTotalRemovalPlan $row $inventory $ScienceRelease.MicromambaSha256
    Write-Host "DELETE root and private cache: $($plan.Root)"
    Write-Host "DELETE executable: $($row.Layout.Micromamba)"
    foreach($name in $plan.Environments){Write-Host "DELETE environment: $name"}
    foreach($path in $plan.External.Keys){Write-Host "DELETE verified integration file: $path"}
    foreach($name in $plan.Integration.Keys){Write-Host "CLEAN UP matching setting: $name"}
    foreach($path in $plan.RemoveRegistrations){Write-Host "REMOVE registration: $path"}
    Write-Host 'PRESERVE other roots, external environments, shared settings and package requests.'
    if(-not (Test-ScienceRemovalConfirmations $plan.Root $selection.IsDefault)){Write-Host 'Cancelled. Nothing was removed.';exit 0}
    $report=Invoke-ScienceTotalRemoval $plan {
        $now=Get-ScienceCleanupInventory $ScienceRelease.MicromambaSha256
        $selected=@($now.Roots|Where-Object {$_.Root -ceq $plan.Root})
        if($selected.Count -ne 1){throw 'The selected root changed or is no longer detected.'}
        Get-ScienceTotalRemovalPlan $selected[0] $now $ScienceRelease.MicromambaSha256
    }
    $report|ConvertTo-Json -Depth 8
    if($report.Status -ne 'SUCCESS'){exit 2}
}catch{Write-Host ('Whole-root removal stopped: '+$_.Exception.Message) -ForegroundColor Yellow;exit 2}
