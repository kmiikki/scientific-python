[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Home', 'Safe')]
    [string]$Mode = 'Auto'
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

function Stop-Removal {
    param([string]$Message)

    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Remove-UserPathEntry {
    param([string]$Entry)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        return
    }

    $target = Get-NormalizedPathText $Entry

    $newParts = @(
        $userPath -split ';' |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                (Get-NormalizedPathText $_) -ine $target
            }
    )

    [Environment]::SetEnvironmentVariable('Path', ($newParts -join ';'), 'User')
}

function Get-ProfilePaths {
    $paths = @()

    try {
        if ($PROFILE.CurrentUserAllHosts) {
            $paths += [string]$PROFILE.CurrentUserAllHosts
        }
    }
    catch {}

    try {
        if ($PROFILE.CurrentUserCurrentHost) {
            $paths += [string]$PROFILE.CurrentUserCurrentHost
        }
    }
    catch {}

    return @($paths | Where-Object { $_ } | Select-Object -Unique)
}

function Remove-ScientificPythonProfileBlock {
    foreach ($profilePath in @(Get-ProfilePaths)) {
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
            continue
        }

        $content = [System.IO.File]::ReadAllText($profilePath)

        $newContent = [regex]::Replace(
            $content,
            '(?ms)^[ \t]*# >>> scientific-python micromamba initialize >>>.*?^[ \t]*# <<< scientific-python micromamba initialize <<<[ \t]*(?:\r?\n)?',
            ''
        )

        if ($newContent -ne $content) {
            if ([string]::IsNullOrWhiteSpace($newContent)) {
                Remove-Item -LiteralPath $profilePath -Force
            }
            else {
                [System.IO.File]::WriteAllText(
                    $profilePath,
                    $newContent.TrimEnd() + [Environment]::NewLine,
                    (New-Object System.Text.UTF8Encoding($true))
                )
            }

            Write-Host "Removed Scientific Python profile block: $profilePath"
        }
    }
}

function Remove-MatchingLegacyMambaBlock {
    param($Layout)

    foreach ($profilePath in @(Get-ProfilePaths)) {
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
            continue
        }

        $content = [System.IO.File]::ReadAllText($profilePath)
        $pattern = '(?ms)^[ \t]*#region[ \t]+mamba initialize.*?^[ \t]*#endregion[ \t]*(?:\r?\n)?'
        $matches = [regex]::Matches($content, $pattern)

        if ($matches.Count -eq 0) {
            continue
        }

        $newContent = $content
        $removedAny = $false

        foreach ($match in @($matches | Sort-Object Index -Descending)) {
            $block = $match.Value

            $mentionsRoot = $block.IndexOf($Layout.Root, [StringComparison]::OrdinalIgnoreCase) -ge 0
            $mentionsExe = $block.IndexOf($Layout.Micromamba, [StringComparison]::OrdinalIgnoreCase) -ge 0

            if ($mentionsRoot -or $mentionsExe) {
                $newContent = $newContent.Remove($match.Index, $match.Length)
                $removedAny = $true
            }
        }

        if ($removedAny) {
            if ([string]::IsNullOrWhiteSpace($newContent)) {
                Remove-Item -LiteralPath $profilePath -Force
            }
            else {
                [System.IO.File]::WriteAllText(
                    $profilePath,
                    $newContent.TrimEnd() + [Environment]::NewLine,
                    (New-Object System.Text.UTF8Encoding($true))
                )
            }

            Write-Host "Removed matching legacy mamba profile block: $profilePath"
        }
    }
}

function Restore-Or-ClearUserVariable {
    param(
        [string]$Name,
        [string]$TargetValue,
        $State,
        [string]$StateProperty
    )

    $hasPrevious = $false
    $previous = $null

    if ($State -and ($State.PSObject.Properties.Name -contains $StateProperty)) {
        $hasPrevious = $true
        $previous = $State.$StateProperty
    }

    if ($hasPrevious) {
        [Environment]::SetEnvironmentVariable($Name, $previous, 'User')
        return
    }

    $current = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ((Get-NormalizedPathText $current) -ieq (Get-NormalizedPathText $TargetValue)) {
        [Environment]::SetEnvironmentVariable($Name, $null, 'User')
    }
}

try {
    $layout = Resolve-SupportedFootprintLayout -Mode $Mode -Interactive
}
catch {
    Stop-Removal $_.Exception.Message
}

Write-Host ''
Write-Host 'Remove micromamba'
Write-Host '================='
Write-Host ''

if (-not $layout) {
    Write-Host 'No supported Home/Safe micromamba installation was detected.'
    exit 0
}

Write-Host "Mode       : $($layout.Mode)"
Write-Host "Root       : $($layout.Root)"
Write-Host "micromamba : $($layout.Micromamba)"

$state = Read-ScienceState -Layout $layout
Write-Host ('State      : ' + $(if ($state) { 'installer state found' } else { 'not found - existing/manual installation' }))

Show-OtherInstallationSummary

if ($env:CONDA_PREFIX -and (Test-PathWithin -Path $env:CONDA_PREFIX -Base $layout.Root)) {
    Stop-Removal 'An environment from this micromamba root is active. Close that PowerShell before removal.'
}

if (Test-Path -LiteralPath $layout.Science -PathType Container) {
    Stop-Removal 'The science environment still exists. Remove it first with menu option 5.'
}

$otherEnvs = @()
if (Test-Path -LiteralPath $layout.Envs -PathType Container) {
    $otherEnvs = @(
        Get-ChildItem -LiteralPath $layout.Envs -Force -Directory -ErrorAction SilentlyContinue
    )
}

if ($otherEnvs.Count -gt 0) {
    Write-Host ''
    Write-Host 'Other environments exist in this supported micromamba root:'
    foreach ($envDir in $otherEnvs) {
        Write-Host "  $($envDir.FullName)"
    }
    Stop-Removal 'Remove or relocate those environments before removing this micromamba root.'
}

Write-Host ''
if (-not $state) {
    Write-Host 'WARNING: This micromamba installation has no installer state file.' -ForegroundColor Yellow
    Write-Host 'It appears to be an existing/manual installation in a supported layout.'
}
elseif (
    ($state.PSObject.Properties.Name -contains 'micromamba_existed_before') -and
    $state.micromamba_existed_before -eq $true
) {
    Write-Host 'WARNING: micromamba existed before this installer first prepared this layout.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Only the selected Home/Safe layout will be removed.'
Write-Host 'Other detected Python/Conda/Mamba installations will not be modified.'
Write-Host ''

$answer = (Read-Host 'Remove this micromamba installation? [y/N]').Trim()
if ($answer -notmatch '^(?i:y|yes|j|ja)$') {
    Write-Host 'No changes were made.'
    exit 0
}

Remove-ScientificPythonSpyderLauncher -Layout $layout
Remove-ScientificPythonProfileBlock
Remove-MatchingLegacyMambaBlock -Layout $layout
Remove-UserPathEntry -Entry $layout.Bin

Restore-Or-ClearUserVariable `
    -Name 'MAMBA_ROOT_PREFIX' `
    -TargetValue $layout.Root `
    -State $state `
    -StateProperty 'previous_mamba_root_prefix'

Restore-Or-ClearUserVariable `
    -Name 'CONDA_PKGS_DIRS' `
    -TargetValue $layout.Pkgs `
    -State $state `
    -StateProperty 'previous_conda_pkgs_dirs'

Restore-Or-ClearUserVariable `
    -Name 'MAMBA_EXE' `
    -TargetValue $layout.Micromamba `
    -State $state `
    -StateProperty 'previous_mamba_exe'

Remove-Item Env:MAMBA_ROOT_PREFIX -ErrorAction SilentlyContinue
Remove-Item Env:CONDA_PKGS_DIRS -ErrorAction SilentlyContinue
Remove-Item Env:MAMBA_EXE -ErrorAction SilentlyContinue

if (
    $state -and
    ($state.PSObject.Properties.Name -contains 'micromamba_executable_backup') -and
    -not [string]::IsNullOrWhiteSpace([string]$state.micromamba_executable_backup)
) {
    $backupPath = [string]$state.micromamba_executable_backup
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

if ($layout.Mode -eq 'Home') {
    if (Test-Path -LiteralPath $layout.Micromamba -PathType Leaf) {
        Remove-Item -LiteralPath $layout.Micromamba -Force
    }

    if (Test-Path -LiteralPath $layout.Root -PathType Container) {
        Remove-Item -LiteralPath $layout.Root -Recurse -Force
    }

    if (Test-Path -LiteralPath $layout.Bin -PathType Container) {
        $binChildren = @(Get-ChildItem -LiteralPath $layout.Bin -Force -ErrorAction SilentlyContinue)
        if ($binChildren.Count -eq 0) {
            Remove-Item -LiteralPath $layout.Bin -Force -ErrorAction SilentlyContinue
        }
    }
}
else {
    if (Test-Path -LiteralPath $layout.Root -PathType Container) {
        Remove-Item -LiteralPath $layout.Root -Recurse -Force
    }
}

if (Test-Path -LiteralPath $layout.Root -PathType Container) {
    Stop-Removal 'The selected micromamba root could not be completely removed.'
}

if ($layout.Mode -eq 'Home' -and (Test-Path -LiteralPath $layout.Micromamba -PathType Leaf)) {
    Stop-Removal 'The selected Home micromamba executable could not be removed.'
}

if (
    $state -and
    ($state.PSObject.Properties.Name -contains 'execution_policy_changed') -and
    $state.execution_policy_changed -eq $true
) {
    $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser

    if ($currentPolicy -eq 'RemoteSigned') {
        $before = [string]$state.execution_policy_before
        if ([string]::IsNullOrWhiteSpace($before)) {
            $before = 'Undefined'
        }

        try {
            Set-ExecutionPolicy -Scope CurrentUser $before -Force
            Write-Host "Restored CurrentUser execution policy to: $before"
        }
        catch {
            Write-Warning "Could not restore the previous execution policy: $($_.Exception.Message)"
        }
    }
}

if ($layout.Mode -eq 'Safe' -and (Test-Path -LiteralPath $layout.ParentRoot -PathType Container)) {
    $children = @(Get-ChildItem -LiteralPath $layout.ParentRoot -Force -ErrorAction SilentlyContinue)

    if ($children.Count -eq 0) {
        $escapedParent = $layout.ParentRoot.Replace("'", "''")
        $adminCode = "Remove-Item -LiteralPath '$escapedParent' -Force -ErrorAction SilentlyContinue"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($adminCode))

        try {
            [void](Start-Process `
                -FilePath 'powershell.exe' `
                -Verb RunAs `
                -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) `
                -Wait `
                -PassThru)
        }
        catch {
            Write-Warning 'The empty C:\micromamba parent directory could not be removed.'
        }
    }
}

Write-Host ''
Write-Host 'The selected micromamba installation was removed.' -ForegroundColor Green
Write-Host 'Windows long path support was intentionally left enabled.'
Write-Host 'Other Python/Conda/Mamba installations were not modified.'
exit 0
