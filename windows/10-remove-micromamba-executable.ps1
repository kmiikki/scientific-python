[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot
$ErrorActionPreference='Stop'

. (Join-Path $PSScriptRoot 'science-common.ps1')
. (Join-Path $PSScriptRoot 'science-release.ps1')
. (Join-Path $PSScriptRoot 'science-update.ps1')
. (Join-Path $PSScriptRoot 'science-root-removal.ps1')

function Get-ScienceOwnedMicromambaSignature {
    param($Layout,[string]$ExpectedSha256)
    $state=Get-SciencePreparedInstallationState $Layout
    if($state.schema_version -ne 2 -or $state.micromamba_existed_before -isnot [bool] -or
        $state.micromamba_existed_before -or -not $state.micromamba_file_signature){
        throw 'Installer ownership of this Micromamba executable could not be verified.'
    }
    Assert-ScienceRegularPath $Layout.Micromamba
    $signature=[ScienceRootNative]::Inspect($Layout.Micromamba,$false)
    if($signature -cne $state.micromamba_file_signature -or
        (Get-ScienceFileSha256 $Layout.Micromamba) -ine $ExpectedSha256){
        throw 'The Micromamba executable differs from the file recorded by the installer.'
    }
    $inventory=Get-ScienceCleanupInventory $ExpectedSha256
    if(@($inventory.Problems).Count){throw 'The Micromamba inventory is incomplete.'}
    Assert-ScienceRemovalResources $inventory $Layout.Root $Layout.Micromamba
    foreach($other in $inventory.Roots){
        if($other.Root -ine $Layout.Root -and
            ($other.Layout.Micromamba -ieq $Layout.Micromamba -or (Test-PathWithin $Layout.Micromamba $other.Root))){
            throw "Another Micromamba directory uses or contains this executable: $($other.Root)"
        }
    }
    Assert-ScienceRootProcesses $Layout.Root $Layout.Micromamba
    return $signature
}

try {
    $expected=$ScienceRelease.MicromambaSha256
    $layout=Select-ScienceRemovalRoot $expected
    if(-not $layout){Write-Host 'Micromamba removal cancelled.';exit 0}
    Initialize-ScienceRootNative
    $signature=Get-ScienceOwnedMicromambaSignature $layout $expected
    Write-Host 'Micromamba executable:'
    Write-Host $layout.Micromamba
    Write-Host 'Micromamba directory:'
    Write-Host $layout.Root
    Write-Host 'This Micromamba may also manage other Python environments.'
    Write-Host 'All environments and package caches will be preserved.'
    if((Read-Host 'Remove this Micromamba executable? [y/N]').Trim() -notmatch '^(?i:y|yes)$'){
        Write-Host 'Micromamba removal cancelled.'
        exit 0
    }

    $lockPath=Join-Path $layout.Root '.science-update.lock'
    Assert-ScienceTransactionPath $lockPath
    $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        if((Get-ScienceOwnedMicromambaSignature $layout $expected) -cne $signature){
            throw 'The Micromamba executable changed during confirmation.'
        }
        $parents=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        [ScienceRootNative]::Remove($layout.Micromamba,$signature,$parents)
    } finally {$lock.Dispose()}
    Write-Host 'The Micromamba executable was removed.'
    exit 0
} catch {
    Write-Host ('Micromamba executable removal stopped: '+$_.Exception.Message) -ForegroundColor Yellow
    exit 2
}
