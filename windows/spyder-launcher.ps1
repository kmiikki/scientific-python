[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$SpyderArguments
)
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot


$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'science-launcher-common.ps1')

$root = Split-Path -Parent $PSCommandPath
$science = Join-Path (Join-Path $root 'envs') 'science'
$spyderExe = Join-Path (Join-Path $science 'Scripts') 'spyder.exe'

if (-not (Test-Path -LiteralPath $spyderExe -PathType Leaf)) {
    Write-Host ''
    Write-Host "ERROR: Spyder was not found:" -ForegroundColor Red
    Write-Host "  $spyderExe" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Reinstall/update Scientific Python with menu option 1.'
    exit 1
}

# Windows micromamba 2.8.1 + Spyder 6.1.7 testing showed that Spyder's
# micromamba-run kernel launch can fail when an already activated science
# environment inherits a PATH component containing non-ASCII characters.
#
# Do NOT change the user's persistent PATH. Filter only this launcher process;
# Spyder and its child kernel processes inherit the filtered PATH.
$originalPath = $env:Path
$parts = @(
    $originalPath -split ';' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$asciiParts = @((Get-ScienceSpyderPath -OriginalPath $originalPath -Science $science) -split ';')

if ($asciiParts.Count -eq 0) {
    Write-Host ''
    Write-Host 'ERROR: No ASCII PATH components remain for the Spyder launcher.' -ForegroundColor Red
    exit 1
}

$debugBefore = $env:SPYDER_DEBUG
$debugFileBefore = $env:SPYDER_DEBUG_FILE
try {
    $env:SPYDER_DEBUG = $null
    $env:SPYDER_DEBUG_FILE = $null
    $env:Path = ($asciiParts -join ';')

    if ($SpyderArguments -and $SpyderArguments.Count -gt 0) {
        $argumentLine = (@($SpyderArguments | ForEach-Object { ConvertTo-ScienceWindowsArgument $_ }) -join ' ')
        Start-Process -FilePath $spyderExe -ArgumentList $argumentLine | Out-Null
    }
    else {
        Start-Process -FilePath $spyderExe | Out-Null
    }
}
finally {
    # This restore affects only the short-lived launcher process.
    # The parent shell and the user's registry PATH were never modified.
    $env:Path = $originalPath
    $env:SPYDER_DEBUG = $debugBefore
    $env:SPYDER_DEBUG_FILE = $debugFileBefore
}

exit 0
