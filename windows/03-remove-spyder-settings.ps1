[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot



$ErrorActionPreference = 'Continue'

$common = Join-Path $PSScriptRoot 'science-common.ps1'
if (-not (Test-Path -LiteralPath $common -PathType Leaf)) {
    Write-Host "ERROR: Missing required file: $common" -ForegroundColor Red
    exit 1
}
. $common

Write-Host ''
Write-Host 'Remove Spyder user settings'
Write-Host '==========================='
Write-Host ''

if (Get-Process -Name spyder -ErrorAction SilentlyContinue) {
    Write-Host 'ERROR: Spyder is running. Close Spyder and try again.' -ForegroundColor Red
    exit 1
}

$dirs = @(Get-SpyderSettingsDirectories)

if ($dirs.Count -eq 0) {
    Write-Host 'No Spyder user-settings directories were found.'
    exit 0
}

Write-Host 'The following Spyder user-settings directories were found:'
foreach ($dir in $dirs) {
    Write-Host "  $($dir.FullName)"
}

Write-Host ''
Write-Host 'WARNING: Spyder settings are user-wide.' -ForegroundColor Yellow
Write-Host 'If another Spyder installation uses the same Windows account, these'
Write-Host 'settings can affect that Spyder as well.'
Write-Host ''

$answer = (Read-Host 'Remove these Spyder user settings? [y/N]').Trim()
if ($answer -notmatch '^(?i:y|yes|j|ja)$') {
    Write-Host 'No changes were made.'
    exit 0
}

foreach ($dir in $dirs) {
    Remove-Item -LiteralPath $dir.FullName -Recurse -Force
}

Write-Host ''
Write-Host 'Spyder user settings removed.' -ForegroundColor Green
exit 0
