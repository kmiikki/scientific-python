[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Home', 'Safe')]
    [string]$Mode = 'Auto'

)
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot


$ErrorActionPreference = 'Continue'
$BaseDir = Split-Path -Parent $PSCommandPath

$utf8 = New-Object System.Text.UTF8Encoding($false)
try { & "$env:SystemRoot\System32\chcp.com" 65001 | Out-Null } catch {}
try { [Console]::InputEncoding = $utf8 } catch {}
try { [Console]::OutputEncoding = $utf8 } catch {}
$global:OutputEncoding = $utf8

$common = Join-Path $BaseDir 'science-common.ps1'
if (-not (Test-Path -LiteralPath $common -PathType Leaf)) {
    Write-Host "ERROR: Missing required file: $common" -ForegroundColor Red
    exit 1
}
. $common
. (Join-Path $BaseDir 'science-release.ps1')

function Get-MicromambaVersionText {
    param($Layout)

    if (-not (Test-Path -LiteralPath $Layout.Micromamba -PathType Leaf)) {
        return 'not installed'
    }

    try {
        $version = (& $Layout.Micromamba --version 2>$null | Out-String).Trim()
        if ($version) { return $version }
    }
    catch {}

    return 'unknown'
}

function Show-State {
    Write-Host 'Current status'
    Write-Host '--------------'
    Write-Host ('Windows long paths : ' + $(if (Get-LongPathsEnabled) { 'enabled' } else { 'disabled' }))

    $statuses = @(Get-ScienceLayoutStatuses)
    foreach ($status in $statuses) {
        $scienceText = if ($status.ScienceExists) { 'science installed' } else { 'science not installed' }
        $mmText = Get-MicromambaVersionText -Layout $status.Layout

        Write-Host ("{0,-4} root          : {1}" -f $status.Mode, $status.Layout.Root)
        Write-Host ("     micromamba      : {0}" -f $mmText)
        Write-Host ("     science         : {0}" -f $scienceText)

        $launcherPaths = Get-ScientificPythonSpyderLauncherPaths -Layout $status.Layout
        $launcherOk = (
            (Test-Path -LiteralPath $launcherPaths.Script -PathType Leaf) -and
            (Test-ScientificPythonSpyderShortcut `
                -ShortcutPath $launcherPaths.Shortcut `
                -LauncherScript $launcherPaths.Script)
        )
        Write-Host ("     Spyder launcher : {0}" -f $(if ($launcherOk) { 'installed' } else { 'not installed' }))
    }

    $spyderCount = @(Get-SpyderSettingsDirectories).Count
    Write-Host ('Spyder settings    : ' + $(if ($spyderCount -gt 0) { "found ($spyderCount)" } else { 'not found' }))
    Write-Host ''
}

function Show-Info {
    Clear-Host
    Write-Host 'Scientific Python setup - Info'
    Write-Host '=============================='
    Write-Host ''
    Write-Host 'Supported installation modes'
    Write-Host '----------------------------'
    Write-Host ''
    Write-Host 'Auto'
    Write-Host '  Uses an existing supported layout when only one is present.'
    Write-Host '  For a new installation, Home is recommended when its paths pass'
    Write-Host '  the conservative safe-path check; otherwise Safe is recommended.'
    Write-Host ''
    Write-Host 'Home'
    $homeLayout = Get-ScienceLayoutByMode -Mode Home
    Write-Host "  Root       : $($homeLayout.Root)"
    Write-Host "  micromamba : $($homeLayout.Micromamba)"
    Write-Host ''
    Write-Host 'Safe'
    $safe = Get-ScienceLayoutByMode -Mode Safe
    Write-Host "  Root       : $($safe.Root)"
    Write-Host "  micromamba : $($safe.Micromamba)"
    Write-Host ''
    Write-Host 'Only Home and Safe are managed by this setup.'
    Write-Host ''

    $safety = Get-HomePathSafety
    Write-Host 'HOME path check'
    Write-Host '---------------'
    Write-Host ('Result: ' + $(if ($safety.IsSafe) { 'safe for automatic Home recommendation' } else { 'risky; Safe is recommended' }))
    if (-not $safety.IsSafe) {
        foreach ($item in $safety.UnsafePaths) {
            Write-Host "  $($item.Name): $($item.Path)"
        }
    }
    Write-Host ''

    Write-Host 'Menu actions'
    Write-Host '------------'
    Write-Host ''
    Write-Host '1  Install/update Scientific Python'
    Write-Host "   Installs or reuses micromamba $($ScienceRelease.MicromambaVersion) and creates or updates the"
    Write-Host '   supported science environment. On every run, unpinned direct'
    Write-Host '   packages are resolved to the newest mutually compatible'
    Write-Host "   conda-forge versions. Python $($ScienceRelease.Python).x; Spyder $($ScienceRelease.Spyder)."
    Write-Host '   It also installs the Scientific Python Spyder launcher. The launcher'
    Write-Host '   filters non-ASCII PATH components only for the Spyder process tree.'
    Write-Host '   The user PATH is never changed by this workaround.'
    Write-Host ''
    Write-Host '2  Apply/repair OpenCL patch'
    Write-Host '   Applies the tested OpenCL activation fix used by Spyder/OpenCV.'
    Write-Host ''
    Write-Host '3  Show OpenCL patch status'
    Write-Host '   Shows the active OpenCL files, hashes and backups.'
    Write-Host ''
    Write-Host '4  Remove Spyder user settings'
    Write-Host '   Removes .spyder* user-settings directories only.'
    Write-Host '   It does not remove Spyder or the science environment.'
    Write-Host '   Note: these settings are user-wide and can also affect another'
    Write-Host '   Spyder installation that uses the same Windows account.'
    Write-Host ''
    Write-Host '5  Remove science environment'
    Write-Host '   Removes the complete science environment. This also removes Spyder'
    Write-Host '   and all Python packages installed inside science. Micromamba is kept.'
    Write-Host '   A supported Home/Safe science environment can be removed even when'
    Write-Host '   it was created manually and has no installer state file.'
    Write-Host ''
    Write-Host '6  Remove micromamba'
    Write-Host '   Removes the selected supported Home/Safe micromamba infrastructure.'
    Write-Host '   It refuses to run while science or another environment in that root'
    Write-Host '   still exists. Other Python/Conda/Mamba installations are not removed.'
    Write-Host ''

    Write-Host 'Supported layout status'
    Write-Host '-----------------------'
    foreach ($status in @(Get-ScienceLayoutStatuses)) {
        Write-Host "$($status.Mode):"
        Write-Host "  Root       : $($status.Layout.Root)"
        Write-Host "  Root exists: $($status.RootExists)"
        Write-Host "  micromamba : $($status.Layout.Micromamba)"
        Write-Host "  mm exists  : $($status.MicromambaExists)"
        Write-Host "  science    : $($status.Layout.Science)"
        Write-Host "  env exists : $($status.ScienceExists)"
        Write-Host "  state file : $($status.StateExists)"

        $launcherPaths = Get-ScientificPythonSpyderLauncherPaths -Layout $status.Layout
        Write-Host "  Spyder cmd : $($launcherPaths.Command)"
        Write-Host "  shortcut   : $($launcherPaths.Shortcut)"
    }
    Write-Host ''

    Show-OtherInstallationSummary -Detailed
    Write-Host ''
}

function Invoke-Step {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptName,

        [string]$ExtraCommand = ''
    )

    $scriptPath = Join-Path $BaseDir $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Write-Host ''
        Write-Host "ERROR: Missing required file: $scriptPath" -ForegroundColor Red
        return 1
    }

    $escapedScript = $scriptPath.Replace("'", "''")

    $invokeLine = if ([string]::IsNullOrWhiteSpace($ExtraCommand)) {
        "& '$escapedScript'"
    }
    else {
        "& '$escapedScript' $ExtraCommand"
    }

    $child = @"
`$ErrorActionPreference = 'Continue'
`$utf8 = New-Object System.Text.UTF8Encoding(`$false)
try { & "`$env:SystemRoot\System32\chcp.com" 65001 | Out-Null } catch {}
try { [Console]::InputEncoding = `$utf8 } catch {}
try { [Console]::OutputEncoding = `$utf8 } catch {}
`$global:OutputEncoding = `$utf8
try {
    $invokeLine
    `$rc = if (`$LASTEXITCODE -is [int]) { `$LASTEXITCODE } else { 0 }
}
catch {
    Write-Host ''
    Write-Host 'UNHANDLED POWERSHELL ERROR' -ForegroundColor Red
    Write-Host '--------------------------' -ForegroundColor Red
    Write-Host (`$_ | Format-List * -Force | Out-String)
    `$rc = 1
}
exit `$rc
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))

    # $rc = Invoke-Step also captures native stdout; inherit the console directly.
    $childArguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    if (-not (Test-ScienceInteractiveConfiguration)) {$childArguments+='-NonInteractive'}
    $process=Start-Process -FilePath 'powershell.exe' -ArgumentList $childArguments `
        -NoNewWindow -Wait -PassThru -ErrorAction Stop
    $rc = $process.ExitCode

    if ($rc -ne 0 -and $rc -ne 10) {
        Write-Host ''
        Write-Host "$ScriptName returned error code $rc." -ForegroundColor Red
        Write-Host 'Use D in the menu for a redacted diagnostic report.'
    }

    return $rc
}

function Pause-Menu {
    Write-Host ''
    [void](Read-Host 'Press Enter to return to the menu')
}

while ($true) {
    Clear-Host
    Write-Host "Windows - Scientific Python V$($ScienceRelease.Version) r$($ScienceRelease.Revision)"
    Write-Host '==========================='
    Write-Host ''
    Show-State

    Write-Host 'Choose an action:'
    Write-Host ''
    Write-Host '  1  Install/update Scientific Python'
    Write-Host '  O  Optional packages'
    Write-Host ''
    Write-Host '  2  Apply/repair the OpenCL patch'
    Write-Host '  3  Show OpenCL patch status'
    Write-Host ''
    Write-Host '  4  Remove Spyder user settings'
    Write-Host '  5  Remove the science environment'
    Write-Host '  6  Remove micromamba'
    Write-Host ''
    Write-Host '  D  Diagnostics (redacted)'
    Write-Host '  I  Info'
    Write-Host '  Q  Quit'
    Write-Host ''

    Write-Host ('Package configuration: ' + (Get-ScienceConfigurationPath))
    $choice = (Read-Host 'Selection').Trim()

    switch -Regex ($choice) {
        '^(?i:1|o|optional packages)$' {
            $optional=$choice -cne '1'
            if($optional -and -not (Test-ScienceInteractiveConfiguration)){
                Write-Host 'Optional package selection requires an interactive console.'
                exit 1
            }
            try {
                $layout = Select-ScienceInstallLayout -Mode $Mode -Interactive
            }
            catch {
                Write-Host ''
                Write-Host "Installation layout was not selected: $($_.Exception.Message)" -ForegroundColor Yellow
                Pause-Menu
                continue
            }

            Write-Host ''
            Write-Host "Selected mode : $($layout.Mode)"
            Write-Host "Selected root : $($layout.Root)"
            Show-OtherInstallationSummary

            try {
                # Preserve uncertain legacy installations before preparation changes Windows settings.
                $null=Initialize-ScienceConfiguration -Root $layout.Root
                if($optional -and -not (Select-ScienceOptionalPackages)){
                    Pause-Menu
                    continue
                }
            } catch {
                Write-Host ('Migration stopped before Windows preparation: '+$_.Exception.Message) -ForegroundColor Red
                Pause-Menu
                continue
            }

            $modeArg = "-Mode '$($layout.Mode)'"
            $prepareArg = "$modeArg -SelectionConfirmed"

            $rc = Invoke-Step '01-prepare-windows.ps1' $prepareArg
            if ($rc -eq 10) {
                Write-Host ''
                Write-Host 'Windows must be restarted before installation can continue.' -ForegroundColor Yellow
                Write-Host ''
                Write-Host 'After the restart:'
                Write-Host '  1. Sign in to the same Windows account.'
                Write-Host '  2. Double-click 00-START-HERE.cmd.'
                Write-Host '  3. Choose option 1 again.'
                Write-Host '  4. Auto will detect the prepared supported layout.'
                Write-Host ''
                [void](Read-Host 'Press Enter to close this window')
                exit 0
            }

            if ($rc -ne 0) {
                Pause-Menu
                continue
            }

            $installArg=if($optional){"$modeArg -SkipReleaseDefaultOffer"}else{$modeArg}
            $rc = Invoke-Step '02-install-science.ps1' $installArg
            if ($rc -eq 0) {
                Write-Host ''
                Write-Host 'Installation finished.' -ForegroundColor Green
                Write-Host 'Close all PowerShell windows before the first normal Spyder test.'
            }

            Pause-Menu
            continue
        }

        '^2$' {
            [void](Invoke-Step 'patch-opencl.ps1' "-Action 'Patch' -Mode 'Auto'")
            Pause-Menu
            continue
        }

        '^3$' {
            [void](Invoke-Step 'patch-opencl.ps1' "-Action 'Status' -Mode 'Auto'")
            Pause-Menu
            continue
        }

        '^4$' {
            [void](Invoke-Step '03-remove-spyder-settings.ps1')
            Pause-Menu
            continue
        }

        '^5$' {
            [void](Invoke-Step '04-remove-science.ps1' "-Mode 'Auto'")
            Pause-Menu
            continue
        }

        '^6$' {
            [void](Invoke-Step '05-remove-micromamba.ps1' "-Mode 'Auto'")
            Pause-Menu
            continue
        }

        '^(?i:d|diagnostics)$' {
            [void](Invoke-Step '06-diagnostics.ps1' "-Mode '$Mode'")
            Pause-Menu
            continue
        }

        '^(?i:i|info)$' {
            Show-Info
            Pause-Menu
            continue
        }

        '^(?i:q|quit|exit)$' {
            exit 0
        }

        default {
            Write-Host ''
            Write-Host 'Unknown selection.'
            Start-Sleep -Seconds 1
        }
    }
}
