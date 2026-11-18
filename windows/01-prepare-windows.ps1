[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Home', 'Safe')]
    [string]$Mode = 'Auto',

    [switch]$SelectionConfirmed
)
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot


$ErrorActionPreference = 'Continue'

$common = Join-Path $PSScriptRoot 'science-common.ps1'
if (-not (Test-Path -LiteralPath $common -PathType Leaf)) {
    Write-Host "ERROR: Missing required file: $common" -ForegroundColor Red
    exit 1
}
. $common

function Stop-Setup {
    param(
        [string]$Message,
        [int]$Code = 1
    )

    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit $Code
}

function Test-UserPathContains {
    param([string]$Entry)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        return $false
    }

    foreach ($part in @($userPath -split ';')) {
        if ((Get-NormalizedPathText $part) -ieq (Get-NormalizedPathText $Entry)) {
            return $true
        }
    }

    return $false
}

try {
    if ($Mode -eq 'Auto') {
        $layout = Select-ScienceInstallLayout -Mode Auto -Interactive
    }
    elseif ($SelectionConfirmed) {
        $layout = Get-ScienceLayoutByMode -Mode $Mode
    }
    else {
        $layout = Select-ScienceInstallLayout -Mode $Mode -Interactive
    }
}
catch {
    Stop-Setup $_.Exception.Message
}

Write-Host ''
Write-Host 'Scientific Python - Windows preparation'
Write-Host '======================================='
Write-Host ''
Write-Host "Mode             : $($layout.Mode)"
Write-Host "Windows user SID : $($layout.Sid)"
Write-Host "ASCII user ID    : $($layout.UserId)"
Write-Host "Micromamba root  : $($layout.Root)"
Write-Host "Micromamba exe   : $($layout.Micromamba)"
Write-Host ''

$longPathsBefore = Get-LongPathsEnabled
$currentUserPolicyBefore = Get-ExecutionPolicy -Scope CurrentUser
$machinePolicy = Get-ExecutionPolicy -Scope MachinePolicy
$userPolicy = Get-ExecutionPolicy -Scope UserPolicy

$rootExistedBefore = Test-Path -LiteralPath $layout.Root -PathType Container
$micromambaExistedBefore = Test-Path -LiteralPath $layout.Micromamba -PathType Leaf
$binPathExistedBefore = Test-UserPathContains -Entry $layout.Bin

$previousMambaRoot = [Environment]::GetEnvironmentVariable('MAMBA_ROOT_PREFIX', 'User')
$previousCondaPkgs = [Environment]::GetEnvironmentVariable('CONDA_PKGS_DIRS', 'User')
$previousMambaExe = [Environment]::GetEnvironmentVariable('MAMBA_EXE', 'User')

if (-not $longPathsBefore) {
    Write-Host 'Windows long path support is currently disabled.'
    $answer = (Read-Host 'Enable Windows long paths? [Y/n]').Trim()
    if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer -notmatch '^(?i:y|yes|j|ja)$') {
        Stop-Setup 'Long path support was not enabled. Installation was not started.'
    }
}

$needsAclSetup = $false

if ($layout.Mode -eq 'Safe') {
    $needsAclSetup = $true

    if (Test-Path -LiteralPath $layout.Root -PathType Container) {
        $probe = Join-Path $layout.Root ('.write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [System.IO.File]::WriteAllText($probe, 'ok', [Text.Encoding]::ASCII)
            Remove-Item -LiteralPath $probe -Force
            $needsAclSetup = $false
        }
        catch {
            $needsAclSetup = $true
        }
    }
}

if (-not $longPathsBefore -or $needsAclSetup) {
    Write-Host ''
    Write-Host 'Windows will request administrator approval (UAC).'
    if ($layout.Mode -eq 'Safe') {
        Write-Host 'Elevation is used only for the machine long-path setting and'
        Write-Host 'the C:\micromamba ACLs required by Safe mode.'
    }
    else {
        Write-Host 'Elevation is used only for the machine long-path setting.'
    }
    Write-Host ''

    $escapedParent = if ($layout.ParentRoot) { $layout.ParentRoot.Replace("'", "''") } else { '' }
    $escapedRoot = $layout.Root.Replace("'", "''")
    $escapedSid = $layout.Sid.Replace("'", "''")
    $setLongPaths = if ($longPathsBefore) { '$false' } else { '$true' }
    $setupSafeAcl = if ($layout.Mode -eq 'Safe') { '$true' } else { '$false' }

    $adminCode = @"
`$ErrorActionPreference = 'Stop'
`$parentRoot = '$escapedParent'
`$userRoot = '$escapedRoot'
`$userSid = New-Object Security.Principal.SecurityIdentifier('$escapedSid')
`$setLongPaths = $setLongPaths
`$setupSafeAcl = $setupSafeAcl

if (`$setLongPaths) {
    Set-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
        -Name 'LongPathsEnabled' `
        -Value 1
}

if (`$setupSafeAcl) {
    `$systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    `$adminsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    `$usersSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    `$none = [Security.AccessControl.InheritanceFlags]::None
    `$inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
    `$propNone = [Security.AccessControl.PropagationFlags]::None
    `$allow = [Security.AccessControl.AccessControlType]::Allow

    if (-not (Test-Path -LiteralPath `$parentRoot -PathType Container)) {
        New-Item -ItemType Directory -Path `$parentRoot -Force | Out-Null
    }

    `$parentAcl = New-Object Security.AccessControl.DirectorySecurity
    `$parentAcl.SetAccessRuleProtection(`$true, `$false)
    `$parentAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        `$systemSid, 'FullControl', `$inherit, `$propNone, `$allow)))
    `$parentAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        `$adminsSid, 'FullControl', `$inherit, `$propNone, `$allow)))
    `$parentAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        `$usersSid, 'ReadAndExecute', `$none, `$propNone, `$allow)))
    Set-Acl -LiteralPath `$parentRoot -AclObject `$parentAcl

    if (-not (Test-Path -LiteralPath `$userRoot -PathType Container)) {
        New-Item -ItemType Directory -Path `$userRoot -Force | Out-Null
    }

    `$userAcl = New-Object Security.AccessControl.DirectorySecurity
    `$userAcl.SetAccessRuleProtection(`$true, `$false)
    `$userAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        `$systemSid, 'FullControl', `$inherit, `$propNone, `$allow)))
    `$userAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        `$adminsSid, 'FullControl', `$inherit, `$propNone, `$allow)))
    `$userAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        `$userSid, 'Modify', `$inherit, `$propNone, `$allow)))
    Set-Acl -LiteralPath `$userRoot -AclObject `$userAcl
}

exit 0
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($adminCode))

    try {
        $proc = Start-Process `
            -FilePath 'powershell.exe' `
            -Verb RunAs `
            -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) `
            -Wait `
            -PassThru
    }
    catch {
        Stop-Setup "Administrator setup could not be started: $($_.Exception.Message)"
    }

    if ($proc.ExitCode -ne 0) {
        Stop-Setup "Administrator setup failed with exit code $($proc.ExitCode)."
    }
}

if (-not (Get-LongPathsEnabled)) {
    Stop-Setup 'Long path support could not be verified.'
}

if (-not (Test-Path -LiteralPath $layout.Root -PathType Container)) {
    try {
        New-Item -ItemType Directory -Force -Path $layout.Root -ErrorAction Stop | Out-Null
    }
    catch {
        Stop-Setup "Could not create $($layout.Root): $($_.Exception.Message)"
    }
}

$probe = Join-Path $layout.Root ('.write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    [System.IO.File]::WriteAllText($probe, 'ok', [Text.Encoding]::ASCII)
    Remove-Item -LiteralPath $probe -Force
}
catch {
    Stop-Setup "The normal user cannot write to $($layout.Root): $($_.Exception.Message)"
}

$state = Read-ScienceState -Layout $layout

if (-not $state) {
    $state = [pscustomobject][ordered]@{
        schema_version = 2
        layout_mode = $layout.Mode
        user_sid = $layout.Sid
        user_id = $layout.UserId
        root = $layout.Root
        micromamba = $layout.Micromamba
        long_paths_was_enabled = $longPathsBefore
        execution_policy_before = [string]$currentUserPolicyBefore
        execution_policy_changed = $false
        root_existed_before = $rootExistedBefore
        micromamba_existed_before = $micromambaExistedBefore
        bin_path_existed_before = $binPathExistedBefore
        previous_mamba_root_prefix = $previousMambaRoot
        previous_conda_pkgs_dirs = $previousCondaPkgs
        previous_mamba_exe = $previousMambaExe
        created_utc = [DateTime]::UtcNow.ToString('o')
    }
}
else {
    $state | Add-Member -NotePropertyName schema_version -NotePropertyValue 2 -Force
    $state | Add-Member -NotePropertyName layout_mode -NotePropertyValue $layout.Mode -Force
    $state | Add-Member -NotePropertyName root -NotePropertyValue $layout.Root -Force
    $state | Add-Member -NotePropertyName micromamba -NotePropertyValue $layout.Micromamba -Force

    if (-not ($state.PSObject.Properties.Name -contains 'execution_policy_changed')) {
        $state | Add-Member -NotePropertyName execution_policy_changed -NotePropertyValue $false -Force
    }
}

if(-not $rootExistedBefore -and -not $micromambaExistedBefore -and -not $state.root_file_identity){
    # An older root is never assigned a fresh-creation identity during update.
    . (Join-Path $PSScriptRoot 'science-root-removal.ps1')
    try{
        Initialize-ScienceRootNative
        $state|Add-Member -NotePropertyName root_file_identity -NotePropertyValue ([ScienceRootNative]::Inspect($layout.Root,$false).Substring(0,26)) -Force
    }catch{
        Write-Warning ('Could not record optional NTFS creation identity: '+$_.Exception.Message)
    }
}
Write-ScienceState -Layout $layout -State $state

if ($machinePolicy -ne 'Undefined' -or $userPolicy -ne 'Undefined') {
    Write-Host ''
    Write-Host "MachinePolicy: $machinePolicy"
    Write-Host "UserPolicy   : $userPolicy"
    Write-Host 'A Group Policy controls PowerShell execution policy on this machine.'
}
else {
    $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser

    if ($currentPolicy -ne 'RemoteSigned') {
        Write-Host ''
        $answer = (Read-Host 'Set CurrentUser PowerShell execution policy to RemoteSigned? [Y/n]').Trim()

        if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer -notmatch '^(?i:y|yes|j|ja)$') {
            Stop-Setup 'PowerShell execution policy was not changed. Installation was not started.'
        }

        try {
            Set-ExecutionPolicy `
                -Scope CurrentUser `
                -ExecutionPolicy RemoteSigned `
                -Force `
                -ErrorAction Stop
        }
        catch {
            if ($_.FullyQualifiedErrorId -notlike 'ExecutionPolicyOverride*') {
                Stop-Setup "Could not set CurrentUser execution policy: $($_.Exception.Message)"
            }
        }

        $verified = Get-ExecutionPolicy -Scope CurrentUser
        if ($verified -ne 'RemoteSigned') {
            Stop-Setup "CurrentUser execution policy verification failed. Expected RemoteSigned, got $verified."
        }

        Write-Host "Verified CurrentUser execution policy: $verified"

        $state = Read-ScienceState -Layout $layout
        $state | Add-Member -NotePropertyName execution_policy_changed -NotePropertyValue $true -Force
        Write-ScienceState -Layout $layout -State $state
    }
}

[Environment]::SetEnvironmentVariable('MAMBA_ROOT_PREFIX', $layout.Root, 'User')
[Environment]::SetEnvironmentVariable('CONDA_PKGS_DIRS', $layout.Pkgs, 'User')
[Environment]::SetEnvironmentVariable('MAMBA_EXE', $layout.Micromamba, 'User')

$env:MAMBA_ROOT_PREFIX = $layout.Root
$env:CONDA_PKGS_DIRS = $layout.Pkgs
$env:MAMBA_EXE = $layout.Micromamba

Write-Host ''
Write-Host 'Windows preparation completed.' -ForegroundColor Green
Write-Host "Mode              = $($layout.Mode)"
Write-Host "MAMBA_ROOT_PREFIX = $($layout.Root)"
Write-Host "CONDA_PKGS_DIRS    = $($layout.Pkgs)"
Write-Host "MAMBA_EXE          = $($layout.Micromamba)"

if (-not $longPathsBefore) {
    Write-Host ''
    Write-Host 'A restart is required because Windows long path support was enabled.' -ForegroundColor Yellow
    exit 10
}

exit 0
