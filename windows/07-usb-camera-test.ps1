[CmdletBinding()]
param(
    [ValidateSet('Auto','Home','Safe')][string]$Mode='Auto',
    [Alias('Device')][ValidateRange(0,99)][int]$CameraIndex,
    [switch]$ListDevices,
    [switch]$All,
    [switch]$Preview,
    [switch]$NoPreview,
    [switch]$Json,
    [ValidateRange(2,120)][int]$Frames=3,
    [ValidateRange(0.5,30)][double]$OpenTimeout=4,
    [ValidateRange(0.5,60)][double]$CaptureTimeout=4,
    [ValidateRange(1,60)][double]$PreviewSeconds=5,
    [ValidateRange(1,100)][int]$ProbeLimit=16
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot
. (Join-Path $PSScriptRoot 'science-common.ps1')
. (Join-Path $PSScriptRoot 'science-launcher-common.ps1')

$explicitIndex=$PSBoundParameters.ContainsKey('CameraIndex')
$interactive=-not ($explicitIndex -or $All -or $ListDevices -or $Json -or [Console]::IsInputRedirected)
$layout=Resolve-ExistingScienceLayout -Mode $Mode -Interactive:$interactive
if (-not $layout) { throw 'Install Scientific Python first.' }
$python=Join-Path $layout.Science 'python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'The selected Science Python interpreter is missing.' }

$camera=Join-Path (Get-ScienceSharedDirectory $PSScriptRoot) 'science-camera.py'
$culture=[Globalization.CultureInfo]::InvariantCulture
$cameraArgs=@('--prefix', $layout.Science, '--frames', [string]$Frames,
    '--open-timeout', $OpenTimeout.ToString($culture), '--capture-timeout', $CaptureTimeout.ToString($culture),
    '--preview-seconds', $PreviewSeconds.ToString($culture), '--probe-limit', [string]$ProbeLimit)
if ($explicitIndex) { $cameraArgs+=@('--device', [string]$CameraIndex) }
if ($ListDevices) { $cameraArgs+='--list' }
if ($All) { $cameraArgs+='--all' }
if ($Preview) { $cameraArgs+='--preview' }
if ($NoPreview) { $cameraArgs+='--no-preview' }
if ($Json) { $cameraArgs+='--json' }

$before=$env:Path
try {
    $env:Path=Get-ScienceSpyderPath -OriginalPath $before -Science $layout.Science
    $library=Join-Path $layout.Science 'Library\bin'
    # Keep the selected prefix's own DLLs accessible even on Unicode Home paths.
    if ($library -notin ($env:Path -split ';')) { $env:Path="$library;$env:Path" }
    & $python -IB $camera @cameraArgs
    $rc=$LASTEXITCODE
} finally {
    $env:Path=$before
}
exit $rc
