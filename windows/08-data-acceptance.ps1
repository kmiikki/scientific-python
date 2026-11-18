[CmdletBinding()]
param(
    [string]$Prefix=(Join-Path $env:USERPROFILE 'micromamba/envs/science'),
    [Parameter(Mandatory=$true)][string]$Output,
    [string[]]$SampleHdf5=@(),
    [string]$ExpectedOpenCV='5.1.0',
    [string]$ExpectedHDF5='1.14.6'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot
. (Join-Path $PSScriptRoot 'science-launcher-common.ps1')
$python=Join-Path $Prefix 'python.exe'
if(-not (Test-Path -LiteralPath $python -PathType Leaf)){throw 'Science Python was not found.'}
$acceptanceTempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temp=Join-Path $acceptanceTempRoot ('science-acceptance-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$oldPath=$env:Path;$oldTemp=$env:TEMP;$oldTmp=$env:TMP;$oldBytecode=$env:PYTHONDONTWRITEBYTECODE
try {
    $env:Path=Get-ScienceSpyderPath -OriginalPath $oldPath -Science $Prefix
    $env:TEMP=$temp;$env:TMP=$temp;$env:PYTHONDONTWRITEBYTECODE='1'
    $arguments=@('-B',(Join-Path $PSScriptRoot 'science-data-acceptance.py'),'--prefix',$Prefix,'--output',[IO.Path]::GetFullPath($Output),'--temp-root',$temp,'--expected-opencv',$ExpectedOpenCV,'--expected-hdf5',$ExpectedHDF5)
    foreach($sample in $SampleHdf5){$arguments+=@('--sample-hdf5',[IO.Path]::GetFullPath($sample))}
    & $python @arguments
    $rc=$LASTEXITCODE
} finally {
    $env:Path=$oldPath;$env:TEMP=$oldTemp;$env:TMP=$oldTmp;$env:PYTHONDONTWRITEBYTECODE=$oldBytecode
    # Delete only this invocation's verified temporary test directory.
    $resolved=[IO.Path]::GetFullPath($temp)
    if([IO.Path]::GetFullPath((Split-Path $resolved -Parent)).TrimEnd('\') -ine $acceptanceTempRoot.TrimEnd('\')){throw 'Acceptance temporary path escaped its root.'}
    if((Split-Path $resolved -Leaf) -notmatch '^science-acceptance-[0-9a-f]{32}$'){throw 'Unexpected acceptance temporary path.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
exit $rc
