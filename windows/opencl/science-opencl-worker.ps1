[CmdletBinding()]
param([ValidateSet('Activate','Deactivate')][string]$Action)
$ErrorActionPreference = 'Stop'
function Initialize-ScienceOpenCLNative {
    if ('ScienceOpenCLNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ScienceOpenCLNative {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern bool CreateDirectoryW(string path, IntPtr security);
 [DllImport("kernel32.dll")] public static extern uint GetConsoleCP();
}
'@
}
function New-ScienceOpenCLScratchDirectory {
    param([string]$Base,[scriptblock]$NameFactory={ 'science-ocl-'+[Guid]::NewGuid().ToString('N') })
    Initialize-ScienceOpenCLNative
    for ($i=0; $i -lt 8; $i++) {
        $leaf=& $NameFactory
        if ($leaf -notmatch '^science-ocl-[A-Za-z0-9_-]+$') { throw 'Invalid scratch leaf.' }
        $candidate=Join-Path $Base $leaf
        if ([ScienceOpenCLNative]::CreateDirectoryW($candidate,[IntPtr]::Zero)) { return $candidate }
        $code=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($code -ne 183) { throw "OpenCL scratch reservation failed ($code)." }
    }
    throw 'OpenCL scratch reservation exhausted.'
}
$owned = $null
try {
    $config = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'science-opencl-config.json')) | ConvertFrom-Json
    $base = [string]$config.ScratchRoot
    if ($base -notmatch '^[A-Za-z0-9:\\ ._-]+$') { throw 'OpenCL scratch path must be ASCII without CMD metacharacters; select Safe mode.' }
    if (-not [IO.Directory]::Exists($base)) { throw 'OpenCL scratch directory is missing.' }
    $owned=New-ScienceOpenCLScratchDirectory -Base $base
    $prior = [Environment]::GetEnvironmentVariable('OCL_ICD_FILENAMES')
    if ($Action -eq 'Activate') {
        $values = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.icd' -File | Sort-Object Name)) {
            $line = [IO.File]::ReadAllLines($file.FullName) | Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace($line)) { $values += $line }
        }
        $new = (@($prior | Where-Object { -not [string]::IsNullOrEmpty($_) }) + $values) -join ';'
        $backup = $prior
    } else {
        $new = [Environment]::GetEnvironmentVariable('OCL_ICD_FILENAMES_CONDA_BACKUP')
        $backup = ''
    }
    $utf8 = New-Object Text.UTF8Encoding($false)
    foreach ($value in @($new,$backup)) {
        if ($value -match '[\r\n]' -or $utf8.GetByteCount([string]$value) -gt 1000) { throw 'OpenCL value exceeds safe CMD input size or contains a newline.' }
    }
    [IO.File]::WriteAllText((Join-Path $owned 'value.txt'), [string]$new, $utf8)
    [IO.File]::WriteAllText((Join-Path $owned 'backup.txt'), [string]$backup, $utf8)
    $cp = [ScienceOpenCLNative]::GetConsoleCP()
    if ($cp -eq 0) { $cp = 65001 }
    $marker = if ($Action -eq 'Activate') { '1' } else { '' }
    # Data never passes through CALL or ENDLOCAL. SET /P reads literal bytes.
    $commands = @"
@echo off
chcp 65001 >nul
set "OCL_ICD_FILENAMES="
set /p "OCL_ICD_FILENAMES="<"$owned\value.txt"
set "OCL_ICD_FILENAMES_CONDA_BACKUP="
set /p "OCL_ICD_FILENAMES_CONDA_BACKUP="<"$owned\backup.txt"
set "SCIENCE_OCL_ACTIVE=$marker"
chcp $cp >nul
del /q "$owned\value.txt" "$owned\backup.txt"
(goto) 2>nul & del /q "$owned\apply.cmd" & rd "$owned" & exit /b 0
"@
    [IO.File]::WriteAllText((Join-Path $owned 'apply.cmd'), $commands.Replace("`r`n","`n").Replace("`n","`r`n"), [Text.Encoding]::ASCII)
    [Console]::WriteLine($owned)
} catch {
    if ($owned -and [IO.Directory]::Exists($owned)) {
        foreach ($name in @('value.txt','backup.txt','apply.cmd')) {
            $file=Join-Path $owned $name
            if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
        }
        [IO.Directory]::Delete($owned)
    }
    [Console]::Error.WriteLine('Scientific Python OpenCL activation failed: ' + $_.Exception.Message)
    exit 1
}
