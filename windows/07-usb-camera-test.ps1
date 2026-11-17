[CmdletBinding()]
param([ValidateSet('Auto','Home','Safe')][string]$Mode='Auto',[ValidateRange(0,99)][int]$CameraIndex=0)
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot


$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'science-common.ps1')
. (Join-Path $PSScriptRoot 'science-launcher-common.ps1')
$layout=Resolve-ExistingScienceLayout -Mode $Mode -Interactive
if (-not $layout) { throw 'Install science first.' }
$before=$env:Path
try {
    $env:Path=Get-ScienceSpyderPath -OriginalPath $before -Science $layout.Science
    & (Join-Path $layout.Science 'python.exe') (Join-Path $PSScriptRoot 'science-runtime-check.py') --prefix $layout.Science --gui --camera $CameraIndex
    $rc=$LASTEXITCODE
} finally { $env:Path=$before }
exit $rc
