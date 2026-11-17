
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot

function ConvertTo-ScienceWindowsArgument {
    param([AllowEmptyString()][string]$Argument)
    # CommandLineToArgvW / CRT quoting: double backslashes before quotes and at end.
    $value=[regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $value=[regex]::Replace($value, '(\\+)$', '$1$1')
    return '"'+$value+'"'
}
function Get-ScienceSpyderPath {
    param([string]$OriginalPath,[string]$Science)
    $parts=@((Join-Path $Science 'Library\bin'))
    $mkv=Join-Path $env:ProgramFiles 'MKVToolNix'
    if (Test-Path -LiteralPath (Join-Path $mkv 'mkvmerge.exe') -PathType Leaf) { $parts += $mkv }
    $parts += @($OriginalPath -split ';')
    $seen=@{}
    @($parts | Where-Object {
        if ([string]::IsNullOrWhiteSpace($_) -or $_ -match '[^\x00-\x7F]') { return $false }
        $key=$_.TrimEnd('\').ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return $false }
        $seen[$key]=$true
        return $true
    }) -join ';'
}
