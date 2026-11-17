[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Home', 'Safe')]
    [string]$Mode = 'Auto'
)
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot


$ErrorActionPreference = 'Continue'

$common = Join-Path $PSScriptRoot 'science-common.ps1'
if (-not (Test-Path -LiteralPath $common -PathType Leaf)) {
    Write-Host "ERROR: Missing required file: $common" -ForegroundColor Red
    exit 1
}
. $common

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
Write-Host "Environment: $($layout.Science)"
Write-Host "micromamba : $($layout.Micromamba)"

$state = Read-ScienceState -Layout $layout
Write-Host ('State      : ' + $(if ($state) { 'installer state found' } else { 'not found - existing/manual environment' }))

Show-OtherInstallationSummary

if (Get-Process -Name spyder -ErrorAction SilentlyContinue) {
    Stop-Removal 'Spyder is running. Close Spyder and try again.'
}

if ($env:CONDA_PREFIX -and (Get-NormalizedPathText $env:CONDA_PREFIX) -ieq (Get-NormalizedPathText $layout.Science)) {
    Stop-Removal 'The science environment is active. Close that PowerShell or deactivate science first.'
}

if (-not (Test-Path -LiteralPath $layout.Micromamba -PathType Leaf)) {
    Stop-Removal "micromamba.exe is missing: $($layout.Micromamba)"
}

Write-Host ''
Write-Host 'This removes the whole science environment, including Spyder and all'
Write-Host 'Python packages installed inside science. Micromamba itself is kept.'
Write-Host ''

$answer = (Read-Host 'Remove the science environment? [y/N]').Trim()
if ($answer -notmatch '^(?i:y|yes|j|ja)$') {
    Write-Host 'No changes were made.'
    exit 0
}

$env:MAMBA_ROOT_PREFIX = $layout.Root
$env:CONDA_PKGS_DIRS = $layout.Pkgs
$env:MAMBA_EXE = $layout.Micromamba

& $layout.Micromamba env remove -p $layout.Science -y
if ($LASTEXITCODE -ne 0) {
    Stop-Removal "micromamba env remove failed with exit code $LASTEXITCODE."
}

if (Test-Path -LiteralPath $layout.Science -PathType Container) {
    Stop-Removal 'The science directory still exists after micromamba removal.'
}

Remove-ScientificPythonSpyderLauncher -Layout $layout

if ($state) {
    $state | Add-Member -NotePropertyName science_removed_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Write-ScienceState -Layout $layout -State $state
}

Write-Host ''
Write-Host 'The science environment was removed.' -ForegroundColor Green
Write-Host 'Micromamba and other detected Python/Conda/Mamba installations were not removed.'
exit 0
