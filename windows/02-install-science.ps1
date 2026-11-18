[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Home', 'Safe')]
    [string]$Mode = 'Auto'
)
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot



$ErrorActionPreference = 'Stop'

# Normal install/update must not inherit Spyder debug-output settings.
# Option 1 runs in its own child PowerShell process, so these process-scope
# assignments do not alter the parent shell or persistent User/Machine values.
$env:SPYDER_DEBUG = $null
$env:SPYDER_DEBUG_FILE = $null


. (Join-Path $PSScriptRoot 'science-release.ps1')
$MicromambaRelease = $ScienceRelease.MicromambaRelease
$MicromambaVersion = $ScienceRelease.MicromambaVersion
$PythonSpec = $ScienceRelease.Python
$SpyderSpec = $ScienceRelease.Spyder

$common = Join-Path $PSScriptRoot 'science-common.ps1'
if (-not (Test-Path -LiteralPath $common -PathType Leaf)) {
    Write-Host "ERROR: Missing required file: $common" -ForegroundColor Red
    exit 1
}
. $common
. (Join-Path $PSScriptRoot 'science-launcher-common.ps1')
. (Join-Path $PSScriptRoot 'science-update.ps1')

function Stop-Install {
    param([string]$Message)

    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    if ($layout -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot '06-diagnostics.ps1'))) {
        try {
            & (Join-Path $PSScriptRoot '06-diagnostics.ps1') -Mode $layout.Mode
        } catch { Write-Host 'Automatic diagnostics could not complete; use menu D after correcting the failure.' }
    }
    exit 1
}

function Add-UserPathEntry {
    param([string]$Entry)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()

    if ($userPath) {
        $parts = @(
            $userPath -split ';' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    $exists = $false
    foreach ($part in $parts) {
        if ((Get-NormalizedPathText $part) -ieq (Get-NormalizedPathText $Entry)) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        [Environment]::SetEnvironmentVariable(
            'Path',
            ((@($Entry) + $parts) -join ';'),
            'User'
        )
    }

    $processParts = @($env:Path -split ';')
    $processHasEntry = $false
    foreach ($part in $processParts) {
        if ((Get-NormalizedPathText $part) -ieq (Get-NormalizedPathText $Entry)) {
            $processHasEntry = $true
            break
        }
    }

    if (-not $processHasEntry) {
        $env:Path = "$Entry;$env:Path"
    }
}

function Set-SafeModeMambaConfig {
    param($Layout)

    if ($Layout.Mode -ne 'Safe') {
        return
    }

    $existing = ''
    if (Test-Path -LiteralPath $Layout.Config -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($Layout.Config)
    }

    if ($existing -match '(?im)^[ \t]*use_sharded_repodata[ \t]*:') {
        $updated = [regex]::Replace(
            $existing,
            '(?im)^[ \t]*use_sharded_repodata[ \t]*:[^\r\n]*',
            'use_sharded_repodata: false'
        )
    }
    else {
        $prefix = if ([string]::IsNullOrWhiteSpace($existing)) {
            ''
        }
        else {
            $existing.TrimEnd() + "`r`n"
        }

        $updated = $prefix + "use_sharded_repodata: false`r`n"
    }

    [System.IO.File]::WriteAllText(
        $Layout.Config,
        $updated,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host "Safe-mode micromamba config: $($Layout.Config)"
    Write-Host '  use_sharded_repodata: false'
}

function Install-PowerShellHook {
    param($Layout)

    $profilePath = [string]$PROFILE.CurrentUserAllHosts
    $profileDir = Split-Path -Parent $profilePath

    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    }

    $startMarker = '# >>> scientific-python micromamba initialize >>>'
    $endMarker = '# <<< scientific-python micromamba initialize <<<'

    $existing = ''
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($profilePath)
    }

    # Do not remove or rewrite a pre-existing standard "#region mamba
    # initialize" block. The setup's own block is appended at the end and
    # therefore takes precedence while this setup is installed. Removing this
    # setup later removes only its own marked block.
    $existing = [regex]::Replace(
        $existing,
        '(?ms)^[ \t]*# >>> scientific-python micromamba initialize >>>.*?^[ \t]*# <<< scientific-python micromamba initialize <<<[ \t]*(?:\r?\n)?',
        ''
    )

    $block = @'
# >>> scientific-python micromamba initialize >>>
$Env:MAMBA_ROOT_PREFIX = [Environment]::GetEnvironmentVariable('MAMBA_ROOT_PREFIX', 'User')
$Env:CONDA_PKGS_DIRS = [Environment]::GetEnvironmentVariable('CONDA_PKGS_DIRS', 'User')
$Env:MAMBA_EXE = [Environment]::GetEnvironmentVariable('MAMBA_EXE', 'User')
if (
    -not [string]::IsNullOrWhiteSpace($Env:MAMBA_EXE) -and
    (Test-Path -LiteralPath $Env:MAMBA_EXE -PathType Leaf)
) {
    (& $Env:MAMBA_EXE 'shell' 'hook' '-s' 'powershell' '-r' $Env:MAMBA_ROOT_PREFIX) |
        Out-String |
        Invoke-Expression
}
# <<< scientific-python micromamba initialize <<<
'@

    $newContent = if ([string]::IsNullOrWhiteSpace($existing)) {
        $block.TrimEnd() + [Environment]::NewLine
    }
    else {
        $existing.TrimEnd() +
            [Environment]::NewLine +
            [Environment]::NewLine +
            $block.TrimEnd() +
            [Environment]::NewLine
    }

    [System.IO.File]::WriteAllText(
        $profilePath,
        $newContent,
        (New-Object System.Text.UTF8Encoding($true))
    )

    $verify = [System.IO.File]::ReadAllText($profilePath)
    if (-not $verify.Contains($startMarker) -or -not $verify.Contains($endMarker)) {
        Stop-Install "Could not verify the PowerShell hook in $profilePath"
    }

    Write-Host "PowerShell hook installed: $profilePath"
}

function Install-SpyderLauncher {
    param(
        [Parameter(Mandatory=$true)]
        $Layout,
        [ValidateNotNullOrEmpty()]
        [string]$SourceDirectory = $PSScriptRoot
    )

    Copy-Item -LiteralPath (Join-Path $SourceDirectory 'science-launcher-common.ps1') -Destination $Layout.Root -Force
    $template = Join-Path $SourceDirectory 'spyder-launcher.ps1'
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
        Stop-Install "Spyder launcher template is missing: $template"
    }

    $paths = Get-ScientificPythonSpyderLauncherPaths -Layout $Layout

    try {
        Copy-Item -LiteralPath $template -Destination $paths.Script -Force -ErrorAction Stop
    }
    catch {
        Stop-Install "Could not install the Spyder launcher script: $($_.Exception.Message)"
    }

    $scriptText = [System.IO.File]::ReadAllText($paths.Script)
    if (
        $scriptText -notmatch 'micromamba-run kernel launch' -or
        -not $scriptText.Contains('Get-ScienceSpyderPath')
    ) {
        Stop-Install "Could not verify the Spyder launcher script: $($paths.Script)"
    }

    $escapedLauncher = $paths.Script.Replace('%', '%%').Replace('"', '""')
    $cmdText = @"
@echo off
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$escapedLauncher" %*
"@

    [System.IO.File]::WriteAllText(
        $paths.Command,
        $cmdText,
        (New-Object System.Text.UTF8Encoding($false))
    )

    if (-not (Test-Path -LiteralPath $paths.Command -PathType Leaf)) {
        Stop-Install "Could not verify the Spyder command launcher: $($paths.Command)"
    }

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        $powershellExe = 'powershell.exe'
    }

    if (Test-Path -LiteralPath $paths.Shortcut -PathType Leaf) {
        if (
            -not (Test-ScientificPythonSpyderShortcut `
                -ShortcutPath $paths.Shortcut `
                -LauncherScript $paths.Script)
        ) {
            Stop-Install "A different shortcut already exists and was not overwritten: $($paths.Shortcut)"
        }
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($paths.Shortcut)
        $shortcut.TargetPath = $powershellExe
        $shortcut.Arguments = (
            '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
            $paths.Script +
            '"'
        )
        $shortcut.WorkingDirectory = $HOME

        $spyderExe = Join-Path (Join-Path $Layout.Science 'Scripts') 'spyder.exe'
        if (Test-Path -LiteralPath $spyderExe -PathType Leaf) {
            $shortcut.IconLocation = "$spyderExe,0"
        }

        $shortcut.Description = 'Scientific Python science environment - Spyder'
        $shortcut.Save()
    }
    catch {
        Stop-Install "Could not create the Spyder Desktop shortcut: $($_.Exception.Message)"
    }

    if (
        -not (Test-ScientificPythonSpyderShortcut `
            -ShortcutPath $paths.Shortcut `
            -LauncherScript $paths.Script)
    ) {
        Stop-Install "Could not verify the Spyder Desktop shortcut: $($paths.Shortcut)"
    }

    Write-Host ''
    Write-Host 'Spyder launcher installed:'
    Write-Host "  Desktop shortcut : $($paths.Shortcut)"
    Write-Host "  Command          : science-spyder"
    Write-Host "  Launcher script  : $($paths.Script)"
    Write-Host ''
    Write-Host 'The launcher filters non-ASCII PATH components only for the Spyder'
    Write-Host 'process tree. The user PATH is not changed.'
}


function Set-ScienceFinalizationStage {
    param($Layout,$State,[string]$Stage)
    $State | Add-Member -NotePropertyName finalization_stage -NotePropertyValue $Stage -Force
    Write-ScienceTransactionJson $Layout.State $State
}

function Complete-ScienceInstallation {
    param($Layout,$State,[string]$RecoveryEvidence)

    Set-ScienceFinalizationStage $Layout $State 'verified-packages'
    $pythonExe = Join-Path $layout.Science 'python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        Stop-Install "Python was not found in $($layout.Science)."
    }

    Write-Host ''
    Write-Host 'Scientific imports are validated by science-runtime-check.py using the active configuration.'

    Set-ScienceFinalizationStage $layout $state 'powershell-hook'
    Install-PowerShellHook -Layout $layout

    $patchScript = Join-Path $PSScriptRoot 'patch-opencl.ps1'
    if (-not (Test-Path -LiteralPath $patchScript -PathType Leaf)) {
        Stop-Install "OpenCL patch script is missing: $patchScript"
    }

    Write-Host ''
    Set-ScienceFinalizationStage $layout $state 'opencl'
    Write-Host 'Applying the OpenCL activation patch...'
    Write-Host ''

    try {
        & $patchScript -Action Patch -EnvPath $layout.Science -Mode $layout.Mode
    }
    catch {
        Stop-Install "OpenCL patch failed: $($_.Exception.Message)"
    }

    Set-ScienceFinalizationStage $layout $state 'launchers'
    Install-SpyderLauncher -Layout $layout -SourceDirectory $PSScriptRoot

    # Keep support probes available independently of the extracted installer ZIP.
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'SHA256SUMS.txt'))) {
        $name=($line -split '  ',2)[1]
        $source=Join-Path $PSScriptRoot $name
        if ($name.StartsWith('shared/')) {$source=Join-Path (Get-ScienceSharedDirectory) $name.Substring(7)}
        $destination=Join-Path $layout.Root $name
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SHA256SUMS.txt') -Destination $layout.Root -Force
    Set-ScienceFinalizationStage $layout $state 'runtime'
    $pathBeforeRuntime = $env:Path
    try {
        . (Join-Path $PSScriptRoot 'science-launcher-common.ps1')
        $env:Path = Get-ScienceSpyderPath -OriginalPath $env:Path -Science $layout.Science
        & $pythonExe (Join-Path $PSScriptRoot 'science-runtime-check.py') --prefix $layout.Science --output (Join-Path $layout.Root 'science-runtime.json')
        if ($LASTEXITCODE -ne 0) { Stop-Install 'Runtime/media checks failed. Run menu D for a redacted report.' }
        $runtimeResult=Read-ScienceJson (Join-Path $layout.Root 'science-runtime.json')
        Write-Host ('Requested packages/imports: '+$runtimeResult.package_selection.status)
        Write-Host ('Release defaults not requested: '+($runtimeResult.package_selection.release_not_requested -join ', '))
        Write-Host ('Release defaults not installed: '+($runtimeResult.package_selection.release_not_installed -join ', '))
    } finally { $env:Path = $pathBeforeRuntime }
    # Preserve the exact solved package records locally; this manifest contains no user paths.
    $manifest = & $layout.Micromamba list --no-rc -r $layout.Root -p $layout.Science --json
    if ($LASTEXITCODE -ne 0) { Stop-Install 'Could not capture the installed package manifest.' }
    [IO.File]::WriteAllText((Join-Path $layout.Root 'science-packages.json'), ($manifest -join "`n"), (New-Object Text.UTF8Encoding($false)))

    if ($state) {
        $state | Add-Member -NotePropertyName layout_mode -NotePropertyValue $layout.Mode -Force
        $state | Add-Member -NotePropertyName micromamba_version -NotePropertyValue $MicromambaVersion -Force
        $state | Add-Member -NotePropertyName python_spec -NotePropertyValue $PythonSpec -Force
        $state | Add-Member -NotePropertyName spyder_version -NotePropertyValue $SpyderSpec -Force
        $nowUtc = [DateTime]::UtcNow.ToString('o')

        if (
            -not ($state.PSObject.Properties.Name -contains 'installed_utc') -or
            [string]::IsNullOrWhiteSpace([string]$state.installed_utc) -or
            -not $scienceExistedBefore
        ) {
            $state | Add-Member -NotePropertyName installed_utc -NotePropertyValue $nowUtc -Force
        }

        $state | Add-Member -NotePropertyName last_sync_utc -NotePropertyValue $nowUtc -Force
        $state | Add-Member -NotePropertyName package_policy -NotePropertyValue 'latest-compatible-unless-pinned' -Force
        $launcherPaths = Get-ScientificPythonSpyderLauncherPaths -Layout $layout
        $state | Add-Member -NotePropertyName installer_version -NotePropertyValue $ScienceRelease.Version -Force
        $state | Add-Member -NotePropertyName installer_revision -NotePropertyValue $ScienceRelease.Revision -Force
        $state | Add-Member -NotePropertyName spyder_launcher_version -NotePropertyValue 2 -Force
        $state | Add-Member -NotePropertyName spyder_launcher_script -NotePropertyValue $launcherPaths.Script -Force
        $state | Add-Member -NotePropertyName spyder_launcher_command -NotePropertyValue $launcherPaths.Command -Force
        $state | Add-Member -NotePropertyName spyder_launcher_shortcut -NotePropertyValue $launcherPaths.Shortcut -Force
        $ownerId=if($state.science_owner_id){$state.science_owner_id}else{[Guid]::NewGuid().ToString('N')}
        $marker=Join-Path $layout.Science '.science-environment-owner'
        Assert-ScienceTransactionPath $marker
        Write-ScienceTransactionJson $marker ([ordered]@{id=$ownerId;sid=$layout.Sid;prefix=$layout.Science})
        $state | Add-Member -NotePropertyName science_owner_id -NotePropertyValue $ownerId -Force
        $state | Add-Member -NotePropertyName recovery_evidence -NotePropertyValue $RecoveryEvidence -Force
        Set-ScienceFinalizationStage $layout $state 'complete'
    }
}

try {
    if ($Mode -eq 'Auto') {
        $layout = Select-ScienceInstallLayout -Mode Auto -Interactive
    }
    else {
        $layout = Get-ScienceLayoutByMode -Mode $Mode
    }
}
catch {
    Stop-Install $_.Exception.Message
}

try {
    $null=Initialize-ScienceConfiguration -Root $layout.Root
    $null=Update-ScienceReleasePackages -Interactive (Test-ScienceInteractiveConfiguration)
    $script:ScienceRelease=Get-ScienceEffectiveRelease
    Assert-ScienceWorkflowConfiguration $script:ScienceRelease
    $packages=@(Get-SciencePackageSpecs)
    Write-Host ('Package configuration: ' + (Get-ScienceConfigurationPath))
    Write-Host ('Validated requests: ' + $packages.Count)
} catch {
    # Migration failures must not launch probes in an existing environment.
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Scientific Python installer'
Write-Host '==========================='
Write-Host ''
Write-Host "Mode        : $($layout.Mode)"
Write-Host "Root prefix : $($layout.Root)"
Write-Host "micromamba  : $MicromambaVersion"
Write-Host "Python      : $PythonSpec"
Write-Host "Spyder      : $SpyderSpec"
Write-Host ''

if (-not (Test-Path -LiteralPath $layout.Root -PathType Container)) {
    Stop-Install 'The selected micromamba root does not exist. Run Windows preparation first.'
}

try { $null=Get-SciencePreparedInstallationState $layout }
catch { Stop-Install $_.Exception.Message }

Write-Host 'Checking write access...'
Write-Host ''

foreach ($dir in @($layout.Bin, $layout.Pkgs, $layout.Envs, $layout.Tmp)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        try {
            New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
        }
        catch {
            Stop-Install "Could not create directory '$dir': $($_.Exception.Message)"
        }
    }

    $probe = Join-Path $dir ('.write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')

    try {
        [System.IO.File]::WriteAllText($probe, 'ok', [Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        Write-Host "  writable: $dir"
    }
    catch {
        Stop-Install "Permission/write test failed for '$dir': $($_.Exception.Message)"
    }
}

[Environment]::SetEnvironmentVariable('MAMBA_ROOT_PREFIX', $layout.Root, 'User')
[Environment]::SetEnvironmentVariable('CONDA_PKGS_DIRS', $layout.Pkgs, 'User')
[Environment]::SetEnvironmentVariable('MAMBA_EXE', $layout.Micromamba, 'User')

$env:MAMBA_ROOT_PREFIX = $layout.Root
$env:CONDA_PKGS_DIRS = $layout.Pkgs
$env:MAMBA_EXE = $layout.Micromamba

# Process-scoped only. The user's normal Windows TEMP/TMP settings are not
# changed. Safe mode therefore keeps installer temp files inside the ASCII tree.
$env:TEMP = $layout.Tmp
$env:TMP = $layout.Tmp

Set-SafeModeMambaConfig -Layout $layout

$arch = if (
    $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or
    $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64'
) {
    Stop-Install 'V12 supports Windows x64 only; ARM64 is not qualified.'
}
else {
    '64'
}

$downloadUrl = "https://github.com/mamba-org/micromamba-releases/releases/download/$MicromambaRelease/micromamba-win-$arch"
$tempExe = Join-Path $layout.Tmp ('micromamba-' + [guid]::NewGuid().ToString('N') + '.exe')

$needDownload = $true

if (Test-Path -LiteralPath $layout.Micromamba -PathType Leaf) {
    try {
        $existingVersion = (& $layout.Micromamba --version | Out-String).Trim()
    }
    catch {
        $existingVersion = ''
    }

    if ($existingVersion -eq $MicromambaVersion -and
        (Get-ScienceFileSha256 -Path $layout.Micromamba) -ieq $ScienceRelease.MicromambaSha256) {
        $needDownload = $false
        Write-Host "micromamba $MicromambaVersion is already installed."
    }
    else {
        Write-Host ''
        Write-Host "Existing micromamba version: $existingVersion"
        Write-Host "Required test version      : $MicromambaVersion"
        Write-Host "Executable                 : $($layout.Micromamba)"
        Write-Host ''
        $answer = (Read-Host "Replace it with micromamba $MicromambaVersion? [y/N]").Trim()

        if ($answer -notmatch '^(?i:y|yes|j|ja)$') {
            Stop-Install 'Existing micromamba was not replaced.'
        }

        $backup = $layout.Micromamba + '.before-scientific-python-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $layout.Micromamba -Destination $backup -Force
        Write-Host "Backup of existing executable: $backup"

        $state = Read-ScienceState -Layout $layout
        if ($state) {
            $state | Add-Member -NotePropertyName micromamba_executable_backup -NotePropertyValue $backup -Force
            Write-ScienceState -Layout $layout -State $state
        }
    }
}

if ($needDownload) {
    Write-Host "Downloading micromamba $MicromambaVersion..."

    & curl.exe -L --fail --silent --show-error -o $tempExe $downloadUrl

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempExe -PathType Leaf)) {
        Stop-Install 'micromamba download failed.'
    }

    if ((Get-ScienceFileSha256 -Path $tempExe) -ine $ScienceRelease.MicromambaSha256) {
        Remove-Item -LiteralPath $tempExe -Force
        Stop-Install 'micromamba SHA256 does not match the pinned Windows standalone artifact.'
    }
    Move-Item -LiteralPath $tempExe -Destination $layout.Micromamba -Force
}

$actualVersion = (& $layout.Micromamba --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $MicromambaVersion) {
    Stop-Install "Expected micromamba $MicromambaVersion but found '$actualVersion'."
}

Add-UserPathEntry -Entry $layout.Bin

if ($layout.Mode -eq 'Safe') {
    Write-Host ''
    Write-Host 'Verifying Safe-mode micromamba configuration...'
    Write-Host ''

    $configOutput = (& $layout.Micromamba config list --sources 2>&1 | Out-String)
    Write-Host $configOutput.TrimEnd()

    if ($configOutput -notmatch '(?im)use_sharded_repodata\s*:\s*false') {
        Stop-Install "micromamba did not load use_sharded_repodata=false from $($layout.Config)."
    }
}

Write-Host ''
Write-Host 'Checking conda-forge metadata...'
Write-Host ''

$scienceChannelArgs=Get-ScienceChannelArguments $script:ScienceRelease
$repoOut = Join-Path $layout.Tmp ('repoquery-' + [guid]::NewGuid().ToString('N') + '.txt')

try {
    & $layout.Micromamba repoquery search "python=$PythonSpec" `
        --override-channels `
        @scienceChannelArgs `
        1> $repoOut

    $repoExit = $LASTEXITCODE

    $repoText = if (Test-Path -LiteralPath $repoOut) {
        [System.IO.File]::ReadAllText($repoOut)
    }
    else {
        ''
    }

    Write-Host $repoText.TrimEnd()
}
finally {
    Remove-Item -LiteralPath $repoOut -Force -ErrorAction SilentlyContinue
}

if (
    $repoExit -ne 0 -or
    $repoText -match '(?i)No entries matching' -or
    $repoText -notmatch '(?im)^\s*python\s+3\.14(?:\.|\s)'
) {
    Stop-Install 'Python 3.14 is not visible in conda-forge metadata.'
}

$packages = @(Get-SciencePackageSpecs)

$scienceExistedBefore = Test-Path -LiteralPath $layout.Science -PathType Container

try {
    Invoke-ScienceEnvironmentSync -Layout $layout -Packages $packages -AfterSync {
        param($PreparedState,$RecoveryEvidence)
        Complete-ScienceInstallation -Layout $layout -State $PreparedState -RecoveryEvidence $RecoveryEvidence
    }
} catch { Stop-Install $_.Exception.Message }


Write-Host ''
Write-Host 'Scientific Python installation/update completed successfully.' -ForegroundColor Green
Write-Host ''
Write-Host "Mode       : $($layout.Mode)"
Write-Host "micromamba : $actualVersion"
Write-Host "science    : $($layout.Science)"
Write-Host ''
Write-Host 'IMPORTANT:'
Write-Host '1. Close all PowerShell windows.'
Write-Host '2. For command-line Python, open a new Windows PowerShell and run:'
Write-Host '     micromamba activate science'
Write-Host '     python --version'
Write-Host '3. Start Spyder with the Desktop shortcut:'
Write-Host '     Scientific Python science - Spyder'
Write-Host '   or run: science-spyder'
Write-Host 'Automated installation checks completed. This development release still requires native Windows/Spyder acceptance testing.'
Write-Host ''
Write-Host 'Do not use "micromamba activate science" followed by plain "spyder" as'
Write-Host 'the recommended Spyder launch path. On Unicode Windows accounts,'
Write-Host 'The Windows toolchain can mis-handle a non-ASCII PATH during Spyder''s'
Write-Host 'nested micromamba-run kernel launch.'

exit 0
