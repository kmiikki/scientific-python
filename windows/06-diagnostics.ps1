[CmdletBinding()]
param([ValidateSet('Auto','Home','Safe')][string]$Mode='Auto',[string]$OutputDirectory)
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot


$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'science-common.ps1')
. (Join-Path $PSScriptRoot 'science-release.ps1')
. (Join-Path $PSScriptRoot 'science-launcher-common.ps1')
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $PSScriptRoot ('diagnostics-'+(Get-Date -Format 'yyyyMMdd-HHmmss')) }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$layout=Resolve-ExistingScienceLayout -Mode $Mode -Interactive
$report=@{schema=12;os_version=[Environment]::OSVersion.Version.ToString();powershell=$PSVersionTable.PSVersion.ToString();release=$ScienceRelease;environment_found=[bool]$layout}
$report.micromamba_inventory=@(Get-ScienceMicromambaInventory $ScienceRelease.MicromambaSha256|ForEach-Object {
    @{layout=$_.Mode;exe_hash_verified=$_.VerifiedExecutable;environment_count=$_.Environments.Count;unknown_count=$_.Unknown.Count}
})
if ($layout) {
    $report.mode=$layout.Mode
    $report.safe_paths=[bool](Test-SafeMicromambaPath $layout.Root)
    $report.context='isolated diagnostic child with supported launcher PATH; run the Python probe in Spyder to verify its kernel'
    $python=Join-Path $layout.Science 'python.exe'
    if (Test-Path -LiteralPath $python) {
        $before=$env:Path
        try {
            $env:Path=Get-ScienceSpyderPath -OriginalPath $before -Science $layout.Science
            & $python (Join-Path $PSScriptRoot 'science-runtime-check.py') --prefix $layout.Science --output (Join-Path $OutputDirectory 'runtime.json') | Out-Null
            $report.runtime_probe_exit=$LASTEXITCODE
            $report.runtime_status=if ($LASTEXITCODE -eq 0) { 'MEETS_V12_R2' } else { 'DOES_NOT_MEET_V12_R2' }
        } finally { $env:Path=$before }
    }
    $meta=Join-Path $layout.Science 'conda-meta'
    $packages=@(Get-ChildItem -LiteralPath $meta -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        $r=Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        @{name=$r.name;version=$r.version;build=$r.build;subdir=$r.subdir}
    })
    $report.packages=$packages
    $report.gtk=@()
    foreach ($relative in @('Library\bin\glib-2.0-0.dll','Library\bin\gdk-pixbuf-query-loaders.exe','Scripts\.librsvg-pre-unlink.bat','Library\lib\gdk-pixbuf-2.0\2.10.0\loaders.cache','Library\lib\gdk-pixbuf-2.0\2.10.0\loaders\libpixbufloader-svg.dll','Library\lib\gdk-pixbuf-2.0\2.10.0\loaders\libpixbufloader_svg.dll')) {
        $target=Join-Path $layout.Science $relative
        $item=@{file=$relative.Replace('\','/');present=[IO.File]::Exists($target)}
        if ($item.present) { $item.sha256=Get-ScienceFileSha256 $target }
        $report.gtk += $item
    }
    $report.opencl=@()
    foreach ($relative in @('etc\conda\activate.d\khronos-opencl-icd-loader_activate.bat','etc\conda\deactivate.d\khronos-opencl-icd-loader_deactivate.bat','Library\etc\OpenCL\vendors\opencl-helper.bat')) {
        $target=Join-Path $layout.Science $relative
        $item=@{file=[IO.Path]::GetFileName($relative);present=(Test-Path -LiteralPath $target)}
        if ($item.present) { $item.sha256=Get-ScienceFileSha256 $target }
        $report.opencl += $item
    }
}
$report.collection_status='SUCCESS'
$report.report_exit=0
# Allowlist only: no username, SID, hostname, full PATH, environment dump or raw logs.
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'diagnostics.json'),($report | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
Write-Host "Redacted diagnostic files saved to: $OutputDirectory"

# Reporting success is independent of a pre-upgrade runtime compliance FAIL.
exit 0
