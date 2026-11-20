[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Home', 'Safe')]
    [string]$Mode = 'Auto'
)
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot


$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot 'science-common.ps1'
if (-not (Test-Path -LiteralPath $common -PathType Leaf)) {
    Write-Host "ERROR: Missing required file: $common" -ForegroundColor Red
    exit 1
}
. $common
. (Join-Path $PSScriptRoot 'science-release.ps1')
. (Join-Path $PSScriptRoot 'science-update.ps1')

function Stop-Removal {
    param([string]$Message)

    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

try {
    $layout = Resolve-ExistingScienceLayout -Mode $Mode -Interactive
}
catch {
    Stop-Removal $_.Exception.Message
}

Write-Host ''
Write-Host 'Remove the science environment'
Write-Host '=============================='
Write-Host ''

if (-not $layout) {
    Write-Host 'The science environment was not found in either supported layout.'
    exit 0
}

Write-Host "Mode       : $($layout.Mode)"
Write-Host "Root       : $($layout.Root)"
Write-Host "micromamba : $($layout.Micromamba)"

try {
    Assert-ScienceTransactionPath $layout.Science
    Assert-ScienceTransactionPath $layout.Micromamba
    $state=Get-SciencePreparedInstallationState $layout
    Assert-ScienceOwnedPrefix $layout $state
    Assert-ScienceRegularPath $layout.Micromamba
    if((Get-ScienceFileSha256 $layout.Micromamba) -cne $ScienceRelease.MicromambaSha256){
        throw 'The selected Micromamba executable does not match the release checksum.'
    }
    Assert-ScienceNotInUse $layout
    if(-not (Test-ScienceInteractiveConfiguration)){throw 'Science removal requires an interactive console.'}
    Show-OtherInstallationSummary
    Write-Host "Selected environment: $($layout.Science)"
    if((Read-Host 'Remove Science environment and its shortcuts? [y/N]').Trim() -notmatch '^(?i:y|yes|j|ja)$'){
        Write-Host 'Science removal cancelled.'
        exit 0
    }

    $lockPath=Join-Path $layout.Root '.science-update.lock'
    Assert-ScienceTransactionPath $lockPath
    $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $state=Get-SciencePreparedInstallationState $layout
        Assert-ScienceOwnedPrefix $layout $state
        Assert-ScienceNotInUse $layout
        Assert-ScienceRegularPath $layout.Micromamba
        if((Get-ScienceFileSha256 $layout.Micromamba) -cne $ScienceRelease.MicromambaSha256){
            throw 'Micromamba changed during removal review.'
        }
        $env:MAMBA_ROOT_PREFIX=$layout.Root
        $env:CONDA_PKGS_DIRS=$layout.Pkgs
        $env:MAMBA_EXE=$layout.Micromamba
        & $layout.Micromamba env remove --no-rc -r $layout.Root -p $layout.Science -y
        if($LASTEXITCODE -ne 0 -or [IO.Directory]::Exists($layout.Science)){
            throw "Micromamba did not remove the Science prefix (exit $LASTEXITCODE)."
        }
        Remove-ScientificPythonSpyderLauncher -Layout $layout
        $state.PSObject.Properties.Remove('science_owner_id')
        $state|Add-Member -NotePropertyName finalization_stage -NotePropertyValue 'removed' -Force
        $state|Add-Member -NotePropertyName science_removed_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-ScienceTransactionJson $layout.State $state
    } finally {
        $lock.Dispose()
    }
} catch {
    Stop-Removal $_.Exception.Message
}

Write-Host ''
Write-Host 'The science environment was removed.' -ForegroundColor Green
Write-Host 'Micromamba and other detected Python/Conda/Mamba installations were not removed.'
exit 0
