# Trust metadata is immutable; the per-user ScientificPackages array is authoritative.
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot
. (Join-Path $PSScriptRoot 'science-config.ps1')
$script:ScienceRelease=Get-ScienceEffectiveRelease
function Get-SciencePackageSpecs { return @($script:ScienceRelease.ScientificPackages) }
function Get-ScienceFileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
}
