[CmdletBinding()]
param(
    [ValidateSet('Patch','Restore','Status')][string]$Action='Patch',
    [ValidateSet('Auto','Home','Safe')][string]$Mode='Auto',
    [string]$EnvName='science', [string]$EnvPath,
    [string]$ScratchRoot
)
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'science-common.ps1')
if (-not $EnvPath) {
    $layout=Resolve-ExistingScienceLayout -Mode $Mode -Interactive
    if (-not $layout) { throw 'science environment was not found.' }
    $EnvPath=$layout.Science
}
$EnvPath=[IO.Path]::GetFullPath($EnvPath)
if (-not $ScratchRoot) { $ScratchRoot=Join-Path (Split-Path (Split-Path $EnvPath -Parent) -Parent) 'tmp' }
$approved=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'opencl-approved.json') -Raw | ConvertFrom-Json
$records=@(Get-ChildItem -LiteralPath (Join-Path $EnvPath 'conda-meta') -Filter 'khronos-opencl-icd-loader-*.json' -ErrorAction SilentlyContinue)
$paths=[ordered]@{
    activate=Join-Path $EnvPath 'etc\conda\activate.d\khronos-opencl-icd-loader_activate.bat'
    helper=Join-Path $EnvPath 'Library\etc\OpenCL\vendors\opencl-helper.bat'
    deactivate=Join-Path $EnvPath 'etc\conda\deactivate.d\khronos-opencl-icd-loader_deactivate.bat'
}
if ($records.Count -eq 0) {
    if (@($paths.Values | Where-Object { Test-Path -LiteralPath $_ }).Count) { throw 'Orphan OpenCL hooks without a package record; no files changed.' }
    Write-Host 'OpenCL patch: not applicable (loader is absent).'
    return
}
if ($records.Count -ne 1) { throw 'Ambiguous OpenCL package records; no files changed.' }
$record=Get-Content -LiteralPath $records[0].FullName -Raw | ConvertFrom-Json
foreach ($key in @('name','version','build')) {
    if ($record.$key -cne $approved.package.$key) { throw 'Unreviewed OpenCL package build; no files changed. Inspect upstream before qualifying it.' }
}
$vendor=Split-Path $paths.helper -Parent
$paths.worker=Join-Path $vendor 'science-opencl-worker.ps1'
$paths.config=Join-Path $vendor 'science-opencl-config.json'
$statePath=Join-Path $EnvPath '.science-opencl-v12.json'
function Hash([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return '' }
    $sha=[Security.Cryptography.SHA256]::Create()
    $stream=[IO.File]::OpenRead($Path)
    try { -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
    finally { $stream.Dispose(); $sha.Dispose() }
}
$expected=@{}; $bytes=@{}
foreach ($key in @('activate','helper','deactivate','worker')) {
    $name=if ($key -eq 'worker') { 'science-opencl-worker.ps1' } else { "$key.bat" }
    $bytes[$key]=[IO.File]::ReadAllBytes((Join-Path (Join-Path $PSScriptRoot 'opencl') $name))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $expected[$key]=(-join ($sha.ComputeHash($bytes[$key]) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}
$config=@{ScratchRoot=[IO.Path]::GetFullPath($ScratchRoot)} | ConvertTo-Json -Compress
$bytes.config=(New-Object Text.UTF8Encoding($false)).GetBytes($config)
$sha=[Security.Cryptography.SHA256]::Create()
try { $expected.config=(-join ($sha.ComputeHash($bytes.config) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
if ($Action -eq 'Status') {
    foreach ($key in $paths.Keys) { Write-Host "$key SHA256 $(Hash $paths[$key])" }
    return
}
if (Get-Process -Name spyder -ErrorAction SilentlyContinue) { throw 'Close Spyder before patch/restore.' }
$lock=$null
try {
    # Retain the lock file to avoid an unlink/open race between patchers.
    $lock=[IO.File]::Open((Join-Path $EnvPath '.science-opencl.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $state=if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
    foreach ($key in @('activate','helper','deactivate')) {
        $h=Hash $paths[$key]
        $known=@($approved.stock.$key,$expected[$key])
        if ($key -ne 'deactivate') { $known += $approved.v11.$key }
        if ($h -notin $known) { throw "Unknown or missing OpenCL $key content; no files changed." }
        $orig=$paths[$key]+'.orig'
        if (Test-Path -LiteralPath $orig) {
            if ((Hash $orig) -ne $approved.stock.$key) { throw "Unverified $key original backup; no files changed." }
        } elseif ($h -ne $approved.stock.$key) { throw "Original $key baseline is missing; no files changed." }
    }
    foreach ($key in @('worker','config')) {
        $h=Hash $paths[$key]
        if ($h -and $h -ne $expected[$key] -and (-not $state -or $h -ne $state.hashes.$key)) { throw "Unknown OpenCL $key payload; no files changed." }
    }
    if ($Action -eq 'Restore') {
        foreach ($key in @('activate','helper','deactivate')) {
            if ((Hash ($paths[$key]+'.orig')) -ne $approved.stock.$key) { throw 'Verified originals are required for restore.' }
            $bytes[$key]=[IO.File]::ReadAllBytes($paths[$key]+'.orig')
            $expected[$key]=$approved.stock.$key
        }
        $keys=@('activate','helper','deactivate')
    } else { $keys=@($paths.Keys) }
    $changed=@($keys | Where-Object { (Hash $paths[$_]) -ne $expected[$_] })
    if ($changed.Count -eq 0) { Write-Host "OpenCL $Action already healthy; no writes/backups."; return }
    if ($Action -eq 'Patch') {
        if ($ScratchRoot -notmatch '^[A-Za-z0-9:\\ ._-]+$') { throw 'Use Safe mode or a private ASCII scratch directory.' }
        [IO.Directory]::CreateDirectory($ScratchRoot) | Out-Null
        foreach ($key in @('activate','helper','deactivate')) {
            $orig=$paths[$key]+'.orig'
            if (-not (Test-Path -LiteralPath $orig)) { [IO.File]::Copy($paths[$key],$orig,$false) }
        }
    }
    $stages=@{}; $old=@{}; $committed=@()
    try {
        # Stage all files first; Replace swaps directory entries, never writes a cache hard link.
        foreach ($key in $changed) {
            $target=$paths[$key]
            $old[$key]=if (Test-Path -LiteralPath $target) { [IO.File]::ReadAllBytes($target) } else { $null }
            $stages[$key]=$target+'.stage-'+[Guid]::NewGuid().ToString('N')
            [IO.File]::WriteAllBytes($stages[$key],$bytes[$key])
            if ((Hash $stages[$key]) -ne $expected[$key]) { throw 'Staged OpenCL verification failed.' }
        }
        foreach ($key in $changed) {
            if (Test-Path -LiteralPath $paths[$key]) { [IO.File]::Replace($stages[$key],$paths[$key],[NullString]::Value) }
            else { [IO.File]::Move($stages[$key],$paths[$key]) }
            $committed += $key
        }
        foreach ($key in $changed) { if ((Hash $paths[$key]) -ne $expected[$key]) { throw 'OpenCL final verification failed.' } }
        $newState=@{schema=12;package=$approved.package;hashes=$expected;action=$Action}
        $stateStage=$statePath+'.stage'
        [IO.File]::WriteAllText($stateStage,($newState | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $statePath) { [IO.File]::Replace($stateStage,$statePath,[NullString]::Value) } else { [IO.File]::Move($stateStage,$statePath) }
    } catch {
        foreach ($key in $committed) {
            if ($null -eq $old[$key]) { [IO.File]::Delete($paths[$key]) }
            else {
                $rollback=$paths[$key]+'.rollback-'+[Guid]::NewGuid().ToString('N')
                [IO.File]::WriteAllBytes($rollback,$old[$key])
                [IO.File]::Replace($rollback,$paths[$key],[NullString]::Value)
            }
        }
        throw
    } finally {
        foreach ($stage in $stages.Values) { if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) } }
    }
    Write-Host "OpenCL $Action completed (verified build; cache links preserved)."
} finally { if ($lock) { $lock.Dispose() } }
