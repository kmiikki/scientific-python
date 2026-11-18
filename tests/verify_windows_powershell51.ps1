# Run from Windows PowerShell 5.1 with the current execution policy unchanged.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run this in Windows PowerShell 5.1 (powershell.exe).'}
Get-ExecutionPolicy -List
$repo=Split-Path -Parent $PSScriptRoot
foreach($file in Get-ChildItem -LiteralPath (Join-Path $repo 'windows'),$PSScriptRoot -Filter '*.ps1'){
    $tokens=$null;$parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors){throw ($file.Name+': '+($parseErrors.Message -join '; '))}
}
$shell=Join-Path $PSHOME 'powershell.exe'
foreach($test in 'test_whole_root_windows.ps1','test_package_progress.ps1','test_configuration.ps1',
                 'test_optional_packages.ps1','test_fresh_commit.ps1','test_removal_policy.ps1','test_windows_recovery.ps1'){
    Write-Host "Running $test in Windows PowerShell 5.1"
    & $shell -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot $test)
    if($LASTEXITCODE -ne 0){throw "$test failed (exit $LASTEXITCODE). Capture this output for the maintainer."}
}
Write-Host 'PASS Windows PowerShell 5.1 installer fixture verification.'
