# Immutable verification bootstrap. No Python is required.
function Get-ScienceSharedDirectory {
    param([string]$Directory=$PSScriptRoot)
    $child=Join-Path $Directory 'shared'
    if (Test-Path -LiteralPath $child -PathType Container) { return $child }
    return Join-Path (Split-Path -Parent $Directory) 'shared'
}
function Assert-ScienceRegularPath {
    param([string]$Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Expected regular file: $Path" }
    $parent=$item.Directory
    while ($parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Redirected path: $Path" }
        $parent=$parent.Parent
    }
}
function Assert-ScienceBundle {
    param([string]$Directory=$PSScriptRoot)
    $manifest=Join-Path $Directory 'SHA256SUMS.txt'; Assert-ScienceRegularPath $manifest
    $shared=Get-ScienceSharedDirectory $Directory
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        if ($line -cnotmatch '^([0-9a-f]{64})  ([A-Za-z0-9_. /-]+)$') { throw 'Invalid immutable manifest entry.' }
        $expected=$Matches[1];$name=$Matches[2]
        if (-not $seen.Add($name) -or $name -eq 'science-release.json' -or $name -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($name)) { throw "Unsafe immutable entry: $name" }
        $base=$Directory;$relative=$name
        if ($name.StartsWith('shared/')) {$base=$shared;$relative=$name.Substring(7)}
        $path=Join-Path $base $relative;Assert-ScienceRegularPath $path
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$actual=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
        if ($actual -cne $expected) { throw "Installer SHA256 mismatch: $name" }
    }
    foreach ($name in @('science-transaction.ps1','science-update.ps1','science-integrity.ps1','science-config.ps1','science-release.ps1','science-installer-release.json','shared/science-release.schema.json','shared/science-release.default.json','shared/StrictJson.cs','shared/science_package_report.py')) {
        if (-not $seen.Contains($name)) { throw "Immutable manifest is incomplete: $name" }
    }
}
