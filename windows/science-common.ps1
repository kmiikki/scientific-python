[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot


$script:ScientificPythonEnvName = 'science'

function Get-ScienceSidInfo {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($sid))
    }
    finally {
        $sha.Dispose()
    }

    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })

    [pscustomobject]@{
        Sid    = $sid
        UserId = 'u-' + $hex.Substring(0, 12)
    }
}

function Get-ScienceLayouts {
    $sidInfo = Get-ScienceSidInfo

    $homeRoot = Join-Path $HOME 'micromamba'
    $homeBin = Join-Path $env:LOCALAPPDATA 'micromamba'

    $safeParent = 'C:\micromamba'
    $safeRoot = Join-Path $safeParent $sidInfo.UserId
    $safeBin = Join-Path $safeRoot 'bin'

    @(
        [pscustomobject]@{
            Mode       = 'Home'
            Sid        = $sidInfo.Sid
            UserId     = $sidInfo.UserId
            ParentRoot = $null
            Root       = $homeRoot
            Bin        = $homeBin
            Micromamba = Join-Path $homeBin 'micromamba.exe'
            Pkgs       = Join-Path $homeRoot 'pkgs'
            Envs       = Join-Path $homeRoot 'envs'
            Science    = Join-Path (Join-Path $homeRoot 'envs') $script:ScientificPythonEnvName
            Tmp        = Join-Path $homeRoot 'tmp'
            Config     = Join-Path $homeRoot '.mambarc'
            State      = Join-Path $homeRoot '.scientific-python-install-state.json'
        }

        [pscustomobject]@{
            Mode       = 'Safe'
            Sid        = $sidInfo.Sid
            UserId     = $sidInfo.UserId
            ParentRoot = $safeParent
            Root       = $safeRoot
            Bin        = $safeBin
            Micromamba = Join-Path $safeBin 'micromamba.exe'
            Pkgs       = Join-Path $safeRoot 'pkgs'
            Envs       = Join-Path $safeRoot 'envs'
            Science    = Join-Path (Join-Path $safeRoot 'envs') $script:ScientificPythonEnvName
            Tmp        = Join-Path $safeRoot 'tmp'
            Config     = Join-Path $safeRoot '.mambarc'
            State      = Join-Path $safeRoot '.scientific-python-install-state.json'
        }
    )
}

function Get-ScienceLayoutByMode {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Home', 'Safe')]
        [string]$Mode
    )

    $layout = Get-ScienceLayouts | Where-Object { $_.Mode -eq $Mode } | Select-Object -First 1
    if (-not $layout) {
        throw "Unknown Scientific Python layout mode: $Mode"
    }
    return $layout
}

function Get-ScientificPythonSpyderLauncherPaths {
    param(
        [Parameter(Mandatory=$true)]
        $Layout
    )

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        $desktop = Join-Path $HOME 'Desktop'
    }

    [pscustomobject]@{
        Script   = Join-Path $Layout.Root 'start-spyder.ps1'
        Command  = Join-Path $Layout.Bin 'science-spyder.cmd'
        Shortcut = Join-Path $desktop 'Scientific Python science - Spyder.lnk'
    }
}

function Test-ScientificPythonSpyderShortcut {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ShortcutPath,

        [Parameter(Mandatory=$true)]
        [string]$LauncherScript
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        return $false
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)

        $targetOk = (
            -not [string]::IsNullOrWhiteSpace([string]$shortcut.TargetPath) -and
            [System.IO.Path]::GetFileName([string]$shortcut.TargetPath) -ieq 'powershell.exe'
        )

        $args = [string]$shortcut.Arguments
        $scriptOk = (
            -not [string]::IsNullOrWhiteSpace($args) -and
            $args.IndexOf($LauncherScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
        )

        return ($targetOk -and $scriptOk)
    }
    catch {
        return $false
    }
}

function Remove-ScientificPythonSpyderLauncher {
    param(
        [Parameter(Mandatory=$true)]
        $Layout
    )

    $paths = Get-ScientificPythonSpyderLauncherPaths -Layout $Layout

    if (
        Test-ScientificPythonSpyderShortcut `
            -ShortcutPath $paths.Shortcut `
            -LauncherScript $paths.Script
    ) {
        Remove-Item -LiteralPath $paths.Shortcut -Force -ErrorAction SilentlyContinue
        Write-Host "Removed Spyder shortcut: $($paths.Shortcut)"
    }

    if (Test-Path -LiteralPath $paths.Command -PathType Leaf) {
        $cmdText = [System.IO.File]::ReadAllText($paths.Command)
        if ($cmdText.IndexOf($paths.Script, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Remove-Item -LiteralPath $paths.Command -Force -ErrorAction SilentlyContinue
            Write-Host "Removed Spyder command launcher: $($paths.Command)"
        }
    }

    if (Test-Path -LiteralPath $paths.Script -PathType Leaf) {
        $scriptText = [System.IO.File]::ReadAllText($paths.Script)
        if (
            $scriptText -match 'Scientific Python Spyder launcher|non-ASCII characters' -or
            $scriptText -match 'micromamba-run kernel launch'
        ) {
            Remove-Item -LiteralPath $paths.Script -Force -ErrorAction SilentlyContinue
            Write-Host "Removed Spyder launcher script: $($paths.Script)"
        }
    }
}

function Test-SafeMicromambaPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    # Deliberately conservative. Windows accepts many more characters, but
    # the Windows micromamba/Spyder/cmd chain has shown failures with Unicode
    # paths, and spaces add avoidable quoting risk.
    return ($Path -match '^[A-Za-z0-9:\\._-]+$')
}

function Get-HomePathSafety {
    $layout = Get-ScienceLayoutByMode -Mode Home
    $unsafe = @()

    foreach ($item in @(
        [pscustomobject]@{ Name = 'Micromamba root'; Path = $layout.Root },
        [pscustomobject]@{ Name = 'Micromamba executable'; Path = $layout.Micromamba },
        [pscustomobject]@{ Name = 'Package cache'; Path = $layout.Pkgs },
        [pscustomobject]@{ Name = 'Temporary directory'; Path = $layout.Tmp }
    )) {
        if (-not (Test-SafeMicromambaPath $item.Path)) {
            $unsafe += $item
        }
    }

    [pscustomobject]@{
        IsSafe      = ($unsafe.Count -eq 0)
        UnsafePaths = $unsafe
    }
}

function Get-ScienceLayoutStatus {
    param(
        [Parameter(Mandatory=$true)]
        $Layout
    )

    $rootExists = Test-Path -LiteralPath $Layout.Root -PathType Container
    $mmExists = Test-Path -LiteralPath $Layout.Micromamba -PathType Leaf
    $scienceExists = Test-Path -LiteralPath $Layout.Science -PathType Container
    $stateExists = Test-Path -LiteralPath $Layout.State -PathType Leaf

    [pscustomobject]@{
        Mode              = $Layout.Mode
        Layout            = $Layout
        RootExists        = $rootExists
        MicromambaExists  = $mmExists
        ScienceExists     = $scienceExists
        StateExists       = $stateExists
        HasFootprint      = ($rootExists -or $mmExists -or $scienceExists -or $stateExists)
    }
}

function Get-ScienceLayoutStatuses {
    @(
        Get-ScienceLayouts | ForEach-Object {
            Get-ScienceLayoutStatus -Layout $_
        }
    )
}

function Get-ScienceMicromambaInventory {
    param([string]$ExpectedSha256)
    $layouts=@(Get-ScienceLayoutStatuses)
    foreach($status in $layouts){
        if(-not $status.HasFootprint){continue}
        $layout=$status.Layout
        $environments=@();$unknown=@();$verified=$false
        try {
            foreach($directory in @($layout.Root,$layout.Envs)){
                $current=[IO.DirectoryInfo]::new($directory)
                while($current){
                    if($current.Exists -and ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Redirected inventory directory.'}
                    $current=$current.Parent
                }
            }
            if(Test-Path -LiteralPath (Join-Path $layout.Root 'conda-meta/history') -PathType Leaf){$environments+=,'base'}
            if(Test-Path -LiteralPath $layout.Envs -PathType Container){
                $entries=@(Get-ChildItem -LiteralPath $layout.Envs -Force -ErrorAction Stop|Select-Object -First 129)
                if($entries.Count -gt 128){$unknown+=,'More than 128 environment entries'}
                foreach($entry in @($entries|Select-Object -First 128)){
                    $history=Join-Path $entry.FullName 'conda-meta/history'
                    try {
                        Assert-ScienceRegularPath $history
                        if($entry.PSIsContainer -and (Test-Path -LiteralPath $history -PathType Leaf)){$environments+=,$entry.Name}
                        else{$unknown+=,$entry.Name}
                    } catch {$unknown+=,$entry.Name}
                }
            }
            if($status.MicromambaExists -and $ExpectedSha256){
                Assert-ScienceRegularPath $layout.Micromamba
                $verified=(Get-FileHash -LiteralPath $layout.Micromamba -Algorithm SHA256 -ErrorAction Stop).Hash -ieq $ExpectedSha256
            }
        } catch {$unknown+=,'Inaccessible or redirected installer path'}
        [pscustomobject]@{Mode=$status.Mode;Root=$layout.Root;Layout=$layout;VerifiedExecutable=$verified;Environments=$environments;Unknown=$unknown}
    }
}

function Select-ScienceRemovalRoot {
    param([string]$ExpectedSha256,[switch]$ScienceOnly)
    if(-not (Test-ScienceInteractiveConfiguration)){throw 'Removal selection requires an interactive console.'}
    $rows=@(Get-ScienceMicromambaInventory $ExpectedSha256)
    if($ScienceOnly){$rows=@($rows|Where-Object {$_.Environments -contains 'science'})}
    if(-not $rows.Count){Write-Host 'No supported removal root was found.';return $null}
    $science=@($rows|Where-Object {$_.VerifiedExecutable -and $_.Environments -contains 'science'})
    $active=@($science|Where-Object {$env:CONDA_PREFIX -ieq $_.Layout.Science})
    $default=if($active.Count -eq 1){$active[0]}elseif($science.Count -eq 1 -and @($rows|Where-Object {$_.Environments -contains 'science'}).Count -eq 1){$science[0]}
    $number=0
    for($i=0;$i -lt $rows.Count;$i++){
        $row=$rows[$i]
        Write-Host ('[{0}] {1} (executable verified: {2}; envs: {3})' -f ($i+1),$row.Root,$row.VerifiedExecutable,($row.Environments -join ', '))
        if($default -and $row.Root -ceq $default.Root){$number=$i+1}
    }
    Write-Host '[0] Cancel'
    $answer=(Read-Host "Select removal root [$number]").Trim()
    if(-not $answer){$answer=[string]$number}
    if($answer -eq '0'){return $null}
    if($answer -notmatch '^[1-9][0-9]?$' -or [int]$answer -gt $rows.Count){throw 'Invalid root selection.'}
    $selected=$rows[([int]$answer)-1]
    if([int]$answer -ne $number -and (Read-Host "Type the exact root path $($selected.Root)") -cne $selected.Root){throw 'Root path did not match exactly; no removal was started.'}
    return $selected.Layout
}

function Select-ScienceInstallLayout {
    param(
        [ValidateSet('Auto', 'Home', 'Safe')]
        [string]$Mode = 'Auto',

        [switch]$Interactive
    )

    $statuses = @(Get-ScienceLayoutStatuses)
    $footprints = @($statuses | Where-Object { $_.HasFootprint })
    $homeSafety = Get-HomePathSafety

    $recommendedMode = $null
    $reason = $null

    if ($Mode -ne 'Auto') {
        $recommendedMode = $Mode
        $reason = 'Mode was explicitly selected.'
    }
    elseif ($footprints.Count -eq 1) {
        $recommendedMode = $footprints[0].Mode
        $reason = "An existing supported $recommendedMode layout was detected."
    }
    elseif ($footprints.Count -gt 1) {
        $reason = 'Both supported layouts have existing files. The installer will not guess.'
    }
    elseif ($homeSafety.IsSafe) {
        $recommendedMode = 'Home'
        $reason = 'The HOME-based micromamba paths pass the conservative safe-path check.'
    }
    else {
        $recommendedMode = 'Safe'
        $reason = 'The HOME-based micromamba paths contain characters that are risky for the Windows micromamba/Spyder toolchain.'
    }

    $selectedMode = $recommendedMode

    if ($Interactive) {
        Write-Host ''
        Write-Host 'Scientific Python installation layout'
        Write-Host '-------------------------------------'
        Write-Host ''
        Write-Host "HOME : $HOME"
        Write-Host ''

        foreach ($status in $statuses) {
            $label = if ($status.HasFootprint) { 'existing files detected' } else { 'not present' }
            Write-Host ("{0,-4}: {1}" -f $status.Mode, $status.Layout.Root)
            Write-Host ("      {0}" -f $label)
        }

        Write-Host ''
        Write-Host $reason

        if ($Mode -eq 'Auto' -and $footprints.Count -gt 1) {
            do {
                $answer = (Read-Host 'Choose Home or Safe [H/S]').Trim()
            } until ($answer -match '^(?i:h|home|s|safe)$')

            $selectedMode = if ($answer -match '^(?i:h|home)$') { 'Home' } else { 'Safe' }
        }
        elseif ($Mode -eq 'Auto') {
            $alternate = if ($recommendedMode -eq 'Home') { 'Safe' } else { 'Home' }
            $key = if ($alternate -eq 'Home') { 'H' } else { 'S' }

            Write-Host ''
            Write-Host "Recommended mode : $recommendedMode"
            Write-Host "Recommended root : $((Get-ScienceLayoutByMode -Mode $recommendedMode).Root)"
            Write-Host ''
            $answer = (Read-Host "Press Enter to accept, or [$key] use $alternate").Trim()

            if (-not [string]::IsNullOrWhiteSpace($answer)) {
                if ($answer -match '^(?i:h|home)$') {
                    $selectedMode = 'Home'
                }
                elseif ($answer -match '^(?i:s|safe)$') {
                    $selectedMode = 'Safe'
                }
                else {
                    throw "Unknown layout selection: $answer"
                }
            }
        }
        else {
            Write-Host ''
            Write-Host "Selected mode : $selectedMode"
            Write-Host "Selected root : $((Get-ScienceLayoutByMode -Mode $selectedMode).Root)"
        }

        if ($selectedMode -eq 'Home' -and -not $homeSafety.IsSafe) {
            Write-Host ''
            Write-Host 'WARNING: risky HOME-based path selected' -ForegroundColor Yellow
            Write-Host '---------------------------------------' -ForegroundColor Yellow
            Write-Host ''
            Write-Host 'The selected Home layout contains characters that have caused'
            Write-Host 'Micromamba/Spyder/package-cache problems on Windows.'
            Write-Host ''
            foreach ($unsafe in $homeSafety.UnsafePaths) {
                Write-Host "$($unsafe.Name):"
                Write-Host "  $($unsafe.Path)"
            }
            Write-Host ''
            Write-Host 'Recommended instead:'
            Write-Host "  $((Get-ScienceLayoutByMode -Mode Safe).Root)"
            Write-Host ''
            $confirm = (Read-Host 'Continue with risky Home mode anyway? [y/N]').Trim()
            if ($confirm -notmatch '^(?i:y|yes|j|ja)$') {
                throw 'Risky Home mode was not accepted.'
            }
        }
    }
    else {
        if (-not $selectedMode) {
            throw 'Both supported layouts have existing files. Select -Mode Home or -Mode Safe.'
        }

        if ($selectedMode -eq 'Home' -and -not $homeSafety.IsSafe) {
            throw 'Home mode is risky on this account. Use Safe mode or run interactively to override the warning.'
        }
    }

    return (Get-ScienceLayoutByMode -Mode $selectedMode)
}

function Resolve-ExistingScienceLayout {
    param(
        [ValidateSet('Auto', 'Home', 'Safe')]
        [string]$Mode = 'Auto',

        [switch]$Interactive
    )

    if ($Mode -ne 'Auto') {
        return (Get-ScienceLayoutByMode -Mode $Mode)
    }

    $found = @(
        Get-ScienceLayoutStatuses |
            Where-Object { $_.ScienceExists }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    if ($found.Count -eq 1) {
        return $found[0].Layout
    }

    if (-not $Interactive) {
        throw 'science exists in both supported layouts. Select -Mode Home or -Mode Safe.'
    }

    Write-Host ''
    Write-Host 'science exists in both supported layouts:'
    foreach ($status in $found) {
        Write-Host "  $($status.Mode): $($status.Layout.Science)"
    }

    do {
        $answer = (Read-Host 'Choose Home or Safe [H/S]').Trim()
    } until ($answer -match '^(?i:h|home|s|safe)$')

    $selected = if ($answer -match '^(?i:h|home)$') { 'Home' } else { 'Safe' }
    return (Get-ScienceLayoutByMode -Mode $selected)
}

function Resolve-SupportedFootprintLayout {
    param(
        [ValidateSet('Auto', 'Home', 'Safe')]
        [string]$Mode = 'Auto',

        [switch]$Interactive
    )

    if ($Mode -ne 'Auto') {
        return (Get-ScienceLayoutByMode -Mode $Mode)
    }

    $found = @(
        Get-ScienceLayoutStatuses |
            Where-Object { $_.HasFootprint }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    if ($found.Count -eq 1) {
        return $found[0].Layout
    }

    if (-not $Interactive) {
        throw 'Both supported layouts have existing files. Select -Mode Home or -Mode Safe.'
    }

    Write-Host ''
    Write-Host 'Both supported layouts have existing files:'
    foreach ($status in $found) {
        Write-Host "  $($status.Mode): $($status.Layout.Root)"
    }

    do {
        $answer = (Read-Host 'Choose Home or Safe [H/S]').Trim()
    } until ($answer -match '^(?i:h|home|s|safe)$')

    $selected = if ($answer -match '^(?i:h|home)$') { 'Home' } else { 'Safe' }
    return (Get-ScienceLayoutByMode -Mode $selected)
}

function Get-LongPathsEnabled {
    try {
        $value = Get-ItemPropertyValue `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
            -Name 'LongPathsEnabled' `
            -ErrorAction Stop
        return ([int]$value -eq 1)
    }
    catch {
        return $false
    }
}

function Get-NormalizedPathText {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))

    try {
        return ([System.IO.Path]::GetFullPath($expanded)).TrimEnd('\')
    }
    catch {
        return $expanded.TrimEnd('\')
    }
}

function Test-PathWithin {
    param(
        [string]$Path,
        [string]$Base
    )

    $p = Get-NormalizedPathText $Path
    $b = Get-NormalizedPathText $Base

    if (-not $p -or -not $b) {
        return $false
    }

    if ($p -ieq $b) {
        return $true
    }

    return $p.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathBelongsToSupportedLayout {
    param([string]$Path)

    foreach ($layout in Get-ScienceLayouts) {
        if (Test-PathWithin -Path $Path -Base $layout.Root) {
            return $true
        }
        if (Test-PathWithin -Path $Path -Base $layout.Bin) {
            return $true
        }
    }

    return $false
}

function Get-RegistryPythonProducts {
    # The Windows Python.org installer registers many individual MSI
    # components (Documentation, Core Interpreter, Development Libraries,
    # etc.) under Uninstall. Those entries are not reliable installation
    # roots and must not be presented as separate Python installations.
    #
    # Therefore the Uninstall registry is used here only for Conda-family
    # distributions whose DisplayName represents the distribution itself.
    # Python.org installations are detected separately from PythonCore.
    $registryPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $items = @()
    $seen = @{}

    foreach ($registryPath in $registryPaths) {
        $entries = @(Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue)

        foreach ($entry in $entries) {
            $name = [string]$entry.DisplayName

            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            if ($name -notmatch '^(?i:Anaconda|Miniconda|Miniforge|Mambaforge)(?:\s|$)') {
                continue
            }

            $kind = if ($name -match '^(?i:Anaconda)') {
                'Anaconda'
            }
            elseif ($name -match '^(?i:Miniconda)') {
                'Miniconda'
            }
            elseif ($name -match '^(?i:Miniforge)') {
                'Miniforge'
            }
            else {
                'Mambaforge'
            }

            $root = $null

            if (-not [string]::IsNullOrWhiteSpace([string]$entry.InstallLocation)) {
                $candidate = Get-NormalizedPathText ([string]$entry.InstallLocation)

                if (
                    $candidate -and
                    (Test-Path -LiteralPath $candidate -PathType Container -ErrorAction SilentlyContinue)
                ) {
                    $root = $candidate
                }
            }

            if ($root -and (Test-PathBelongsToSupportedLayout $root)) {
                continue
            }

            $key = if ($root) {
                ($kind + '|' + $root).ToLowerInvariant()
            }
            else {
                ($kind + '|registry|' + $name).ToLowerInvariant()
            }

            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $items += [pscustomobject]@{
                    Kind   = $kind
                    Name   = $name
                    Root   = $root
                    Source = 'Windows uninstall registry'
                }
            }
        }
    }

    return @($items | Sort-Object Kind, Name, Root)
}

function Get-PythonCoreRegistryInstallations {
    # Python.org publishes actual interpreter installation metadata under
    # Software\Python\PythonCore. This is a much better source than the
    # component-level Uninstall entries.
    $basePaths = @(
        'HKCU:\Software\Python\PythonCore',
        'HKCU:\Software\WOW6432Node\Python\PythonCore',
        'HKLM:\Software\Python\PythonCore',
        'HKLM:\Software\WOW6432Node\Python\PythonCore'
    )

    $items = @()
    $seen = @{}

    foreach ($basePath in $basePaths) {
        if (-not (Test-Path -LiteralPath $basePath -PathType Container -ErrorAction SilentlyContinue)) {
            continue
        }

        foreach ($versionKey in @(Get-ChildItem -LiteralPath $basePath -ErrorAction SilentlyContinue)) {
            $version = [string]$versionKey.PSChildName
            $installKeyPath = Join-Path $versionKey.PSPath 'InstallPath'

            if (-not (Test-Path -LiteralPath $installKeyPath -ErrorAction SilentlyContinue)) {
                continue
            }

            $root = $null
            $executable = $null

            try {
                $installKey = Get-Item -LiteralPath $installKeyPath -ErrorAction Stop
                $root = [string]$installKey.GetValue('')

                if ([string]::IsNullOrWhiteSpace($root)) {
                    $root = $null
                }
                else {
                    $root = Get-NormalizedPathText $root
                }

                $exeValue = [string]$installKey.GetValue('ExecutablePath')
                if (-not [string]::IsNullOrWhiteSpace($exeValue)) {
                    $executable = Get-NormalizedPathText $exeValue
                }
            }
            catch {
                continue
            }

            if (-not $root -and $executable) {
                try {
                    $root = Get-NormalizedPathText (Split-Path -Parent $executable)
                }
                catch {
                    $root = $null
                }
            }

            if (-not $root) {
                continue
            }

            if (Test-PathBelongsToSupportedLayout $root) {
                continue
            }

            $pythonExe = if ($executable) {
                $executable
            }
            else {
                Join-Path $root 'python.exe'
            }

            if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf -ErrorAction SilentlyContinue)) {
                continue
            }

            $key = $root.ToLowerInvariant()

            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $items += [pscustomobject]@{
                    Kind       = 'Python'
                    Name       = "Python $version"
                    Root       = $root
                    Executable = $pythonExe
                    Source     = 'PythonCore registry'
                }
            }
        }
    }

    return @($items | Sort-Object Name, Root)
}

function Get-KnownPythonDistributionRoots {
    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($HOME)) {
        foreach ($spec in @(
            @('Anaconda',   'anaconda3'),
            @('Miniconda',  'miniconda3'),
            @('Miniforge',  'miniforge3'),
            @('Mambaforge', 'mambaforge')
        )) {
            $candidates += [pscustomobject]@{
                Kind = $spec[0]
                Root = Join-Path $HOME $spec[1]
            }
        }
    }

    $localAppData = $env:LOCALAPPDATA
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        foreach ($spec in @(
            @('Anaconda',   'anaconda3'),
            @('Miniconda',  'miniconda3'),
            @('Miniforge',  'miniforge3'),
            @('Mambaforge', 'mambaforge')
        )) {
            $candidates += [pscustomobject]@{
                Kind = $spec[0]
                Root = Join-Path $localAppData $spec[1]
            }
        }

        $continuum = Join-Path $localAppData 'Continuum'

        foreach ($spec in @(
            @('Anaconda',  'anaconda3'),
            @('Miniconda', 'miniconda3')
        )) {
            $candidates += [pscustomobject]@{
                Kind = $spec[0]
                Root = Join-Path $continuum $spec[1]
            }
        }
    }

    $programData = $env:ProgramData
    if (-not [string]::IsNullOrWhiteSpace($programData)) {
        foreach ($spec in @(
            @('Anaconda',   'anaconda3'),
            @('Miniconda',  'miniconda3'),
            @('Miniforge',  'miniforge3'),
            @('Mambaforge', 'mambaforge')
        )) {
            $candidates += [pscustomobject]@{
                Kind = $spec[0]
                Root = Join-Path $programData $spec[1]
            }
        }
    }

    foreach ($programFiles in @(
        $env:ProgramFiles,
        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    )) {
        if ([string]::IsNullOrWhiteSpace($programFiles)) {
            continue
        }

        foreach ($spec in @(
            @('Anaconda',   'Anaconda3'),
            @('Miniconda',  'Miniconda3'),
            @('Miniforge',  'Miniforge3'),
            @('Mambaforge', 'Mambaforge')
        )) {
            $candidates += [pscustomobject]@{
                Kind = $spec[0]
                Root = Join-Path $programFiles $spec[1]
            }
        }
    }

    foreach ($spec in @(
        @('Anaconda',   'C:\Anaconda3'),
        @('Miniconda',  'C:\Miniconda3'),
        @('Miniforge',  'C:\Miniforge3'),
        @('Mambaforge', 'C:\Mambaforge')
    )) {
        $candidates += [pscustomobject]@{
            Kind = $spec[0]
            Root = $spec[1]
        }
    }

    $items = @()
    $seen = @{}

    foreach ($candidate in $candidates) {
        $root = Get-NormalizedPathText $candidate.Root

        if (-not $root) {
            continue
        }

        if (Test-PathBelongsToSupportedLayout $root) {
            continue
        }

        if (-not (Test-Path -LiteralPath $root -PathType Container -ErrorAction SilentlyContinue)) {
            continue
        }

        $markers = @(
            (Join-Path $root 'python.exe'),
            (Join-Path $root 'Scripts\conda.exe'),
            (Join-Path $root 'condabin\conda.bat')
        )

        $markerFound = $false
        foreach ($marker in $markers) {
            if (Test-Path -LiteralPath $marker -PathType Leaf -ErrorAction SilentlyContinue) {
                $markerFound = $true
                break
            }
        }

        if (-not $markerFound) {
            continue
        }

        $key = $root.ToLowerInvariant()

        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $items += [pscustomobject]@{
                Kind   = $candidate.Kind
                Name   = "$($candidate.Kind) installation"
                Root   = $root
                Source = 'Known installation location'
            }
        }
    }

    return @($items | Sort-Object Kind, Root)
}

function Get-DetectedPythonDistributions {
    $items = @()
    $seenRoots = @{}
    $seenNames = @{}

    foreach ($item in @(Get-KnownPythonDistributionRoots)) {
        $rootKey = $item.Root.ToLowerInvariant()

        if (-not $seenRoots.ContainsKey($rootKey)) {
            $seenRoots[$rootKey] = $true
            $items += $item
        }
    }

    foreach ($item in @(Get-PythonCoreRegistryInstallations)) {
        $rootKey = $item.Root.ToLowerInvariant()

        if (-not $seenRoots.ContainsKey($rootKey)) {
            $seenRoots[$rootKey] = $true
            $items += $item
        }
    }

    foreach ($item in @(Get-RegistryPythonProducts)) {
        if ($item.Root) {
            $rootKey = $item.Root.ToLowerInvariant()

            if ($seenRoots.ContainsKey($rootKey)) {
                continue
            }

            $seenRoots[$rootKey] = $true
            $items += $item
            continue
        }

        $nameKey = ($item.Kind + '|' + $item.Name).ToLowerInvariant()

        if (-not $seenNames.ContainsKey($nameKey)) {
            $seenNames[$nameKey] = $true
            $items += $item
        }
    }

    return @($items | Sort-Object Kind, Name, Root)
}

function Get-DetectedExternalTools {
    $names = @('python', 'python3', 'py', 'micromamba', 'mamba', 'conda')
    $items = @()
    $seen = @{}

    foreach ($name in $names) {
        $commands = @(Get-Command $name -All -ErrorAction SilentlyContinue)

        foreach ($command in $commands) {
            $path = $null

            if ($command.Path) {
                $path = [string]$command.Path
            }
            elseif (
                $command.Source -and
                (Test-Path -LiteralPath $command.Source -PathType Leaf -ErrorAction SilentlyContinue)
            ) {
                $path = [string]$command.Source
            }

            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }

            $normalized = Get-NormalizedPathText $path
            if (Test-PathBelongsToSupportedLayout $normalized) {
                continue
            }

            $classification = 'Command path'

            if (
                $name -eq 'py' -and
                (Split-Path -Leaf $normalized) -ieq 'py.exe'
            ) {
                $classification = 'Python Launcher'
            }
            elseif (
                $normalized -match '(?i)\\Microsoft\\WindowsApps\\' -and
                $name -match '^(?i:python|python3)$'
            ) {
                $classification = 'Windows App Execution Alias'
            }
            elseif ($name -match '^(?i:python|python3)$') {
                $classification = 'Python executable'
            }
            elseif ($name -eq 'conda') {
                $classification = 'Conda executable'
            }
            elseif ($name -eq 'mamba') {
                $classification = 'Mamba executable'
            }
            elseif ($name -eq 'micromamba') {
                $classification = 'Micromamba executable'
            }

            $key = ($classification + '|' + $normalized).ToLowerInvariant()

            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $items += [pscustomobject]@{
                    Tool           = $name
                    Classification = $classification
                    Path           = $normalized
                    Source         = 'Get-Command'
                }
            }
        }

        $whereExe = Join-Path $env:SystemRoot 'System32\where.exe'

        if (Test-Path -LiteralPath $whereExe -PathType Leaf) {
            $whereOutput = @(& $whereExe $name 2>$null)

            foreach ($raw in $whereOutput) {
                $path = [string]$raw

                if ([string]::IsNullOrWhiteSpace($path)) {
                    continue
                }

                $normalized = Get-NormalizedPathText $path
                if (Test-PathBelongsToSupportedLayout $normalized) {
                    continue
                }

                $classification = 'Command path'

                if (
                    $name -eq 'py' -and
                    (Split-Path -Leaf $normalized) -ieq 'py.exe'
                ) {
                    $classification = 'Python Launcher'
                }
                elseif (
                    $normalized -match '(?i)\\Microsoft\\WindowsApps\\' -and
                    $name -match '^(?i:python|python3)$'
                ) {
                    $classification = 'Windows App Execution Alias'
                }
                elseif ($name -match '^(?i:python|python3)$') {
                    $classification = 'Python executable'
                }
                elseif ($name -eq 'conda') {
                    $classification = 'Conda executable'
                }
                elseif ($name -eq 'mamba') {
                    $classification = 'Mamba executable'
                }
                elseif ($name -eq 'micromamba') {
                    $classification = 'Micromamba executable'
                }

                $key = ($classification + '|' + $normalized).ToLowerInvariant()

                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    $items += [pscustomobject]@{
                        Tool           = $name
                        Classification = $classification
                        Path           = $normalized
                        Source         = 'where.exe'
                    }
                }
            }
        }
    }

    return @($items | Sort-Object Classification, Tool, Path)
}

function Get-ExternalEnvironmentReferences {
    $names = @(
        'CONDA_EXE',
        'CONDA_PREFIX',
        'MAMBA_EXE',
        'MAMBA_ROOT_PREFIX',
        'CONDA_PKGS_DIRS'
    )

    $items = @()
    $seen = @{}

    foreach ($name in $names) {
        foreach ($scope in @('Process', 'User')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)

            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $parts = @(
                $value -split ';' |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )

            $externalParts = @()

            foreach ($part in $parts) {
                if (-not (Test-PathBelongsToSupportedLayout $part)) {
                    $externalParts += $part
                }
            }

            if ($externalParts.Count -eq 0) {
                continue
            }

            $externalValue = $externalParts -join ';'
            $key = ($name + '|' + $scope + '|' + $externalValue).ToLowerInvariant()

            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $items += [pscustomobject]@{
                    Name  = $name
                    Scope = $scope
                    Value = $externalValue
                }
            }
        }
    }

    return @($items | Sort-Object Name, Scope)
}

function Test-PathBelongsToDetectedDistribution {
    param(
        [string]$Path,
        [array]$Distributions
    )

    foreach ($distribution in $Distributions) {
        if (
            $distribution.Root -and
            (Test-PathWithin -Path $Path -Base $distribution.Root)
        ) {
            return $true
        }
    }

    return $false
}

function Show-OtherInstallationSummary {
    param([switch]$Detailed)

    $distributions = @(Get-DetectedPythonDistributions)
    $tools = @(
        Get-DetectedExternalTools |
            Where-Object {
                -not (Test-PathBelongsToDetectedDistribution `
                    -Path $_.Path `
                    -Distributions $distributions)
            }
    )
    $refs = @(Get-ExternalEnvironmentReferences)

    $total = $distributions.Count + $tools.Count + $refs.Count

    if ($total -eq 0) {
        if ($Detailed) {
            Write-Host 'Other Python-related software detected'
            Write-Host '--------------------------------------'
            Write-Host 'none detected through PATH, Get-Command, where.exe,'
            Write-Host 'Windows uninstall registry, known installation roots or'
            Write-Host 'relevant environment variables'
        }
        return
    }

    if (-not $Detailed) {
        Write-Host ''
        Write-Host "Other Python-related references detected: $total"
        Write-Host 'They are informational only and will not be modified by this setup.'
        Write-Host 'Use I (Info) in the main menu for details.'
        return
    }

    Write-Host 'Other Python-related software detected'
    Write-Host '--------------------------------------'

    if ($distributions.Count -gt 0) {
        Write-Host ''
        Write-Host 'Distributions/products:'

        foreach ($item in $distributions) {
            Write-Host "  $($item.Kind): $($item.Name)"

            if ($item.Root) {
                Write-Host "    Root   : $($item.Root)"
            }
            else {
                Write-Host '    Root   : not reported by Windows'
            }

            Write-Host "    Source : $($item.Source)"
        }
    }

    $launchers = @($tools | Where-Object { $_.Classification -eq 'Python Launcher' })
    $aliases = @($tools | Where-Object { $_.Classification -eq 'Windows App Execution Alias' })
    $otherCommands = @(
        $tools |
            Where-Object {
                $_.Classification -ne 'Python Launcher' -and
                $_.Classification -ne 'Windows App Execution Alias'
            }
    )

    if ($launchers.Count -gt 0) {
        Write-Host ''
        Write-Host 'Python Launcher:'
        foreach ($item in $launchers) {
            Write-Host "  $($item.Path)"
        }
    }

    if ($aliases.Count -gt 0) {
        Write-Host ''
        Write-Host 'Windows App Execution Aliases:'
        foreach ($item in $aliases) {
            Write-Host "  $($item.Path)"
        }
    }

    if ($otherCommands.Count -gt 0) {
        Write-Host ''
        Write-Host 'Other command paths:'
        foreach ($item in $otherCommands) {
            Write-Host "  $($item.Classification): $($item.Path)"
        }
    }

    if ($refs.Count -gt 0) {
        Write-Host ''
        Write-Host 'Other environment references:'
        foreach ($item in $refs) {
            Write-Host "  $($item.Name) [$($item.Scope)] = $($item.Value)"
        }
    }

    Write-Host ''
    Write-Host 'These installations/references are not managed or modified by this setup.'
    Write-Host 'The setup does not scan the whole disk.'
}

function Read-ScienceState {
    param(
        [Parameter(Mandatory=$true)]
        $Layout
    )

    if (-not (Test-Path -LiteralPath $Layout.State -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Layout.State -Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Write-ScienceState {
    param(
        [Parameter(Mandatory=$true)]
        $Layout,

        [Parameter(Mandatory=$true)]
        $State
    )

    $json = $State | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        $Layout.State,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Get-SpyderSettingsDirectories {
    @(
        Get-ChildItem -LiteralPath $HOME -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '.spyder*' }
    )
}
