
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot

# Transaction preflight and the narrowly scoped legacy librsvg cache hook guard.
# Source this file; it has no top-level package or persistent-environment mutations.
function Get-ScienceRecords {
    param([string]$Prefix)
    $records=@{}
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Prefix 'conda-meta') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        Assert-ScienceRegularPath $file.FullName
        $r=[IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        if ($r.name) { if($records.ContainsKey([string]$r.name)){throw "Duplicate installed package record: $($r.name)"}; $records[$r.name]=$r }
    }
    return $records
}
function ConvertTo-ScienceVersion {
    param([string]$Text)
    if ($Text -notmatch '^\d+\.\d+(?:\.\d+)?(?:\.\d+)?$') { throw 'Unreviewed non-stable package version.' }
    $parts=@($Text.Split('.')); while ($parts.Count -lt 3) { $parts += '0' }
    return [version]($parts -join '.')
}
function Get-ScienceMediaFloors {
    param($Records)
    $floors=@{opencv=[string]$ScienceRelease.OpenCV;ffmpeg=[string]$ScienceRelease.FFmpeg}
    foreach ($name in @('opencv','ffmpeg')) {
        if ($Records.ContainsKey($name) -and (ConvertTo-ScienceVersion $Records[$name].version) -gt (ConvertTo-ScienceVersion $floors[$name])) { $floors[$name]=[string]$Records[$name].version }
    }
    return $floors
}
function Assert-SciencePlan {
    param($Plan,$Before,$Floors,[string[]]$Packages)
    if (-not $Plan.success) { throw 'No compatible solution; no package changes have been started.' }
    $after=@{}; foreach ($key in $Before.Keys) { $after[$key]=$Before[$key] }
    foreach ($r in @($Plan.actions.UNLINK)) { if ($r) { $after.Remove([string]$r.name) } }
    foreach ($r in @($Plan.actions.LINK)) { if ($r) { $after[[string]$r.name]=$r } }
    foreach ($name in @('opencv','ffmpeg')) {
        if (-not $after.ContainsKey($name) -or (ConvertTo-ScienceVersion $after[$name].version) -lt (ConvertTo-ScienceVersion $Floors[$name])) { throw "Refusing media downgrade or missing $name before package changes." }
    }
    if ((ConvertTo-ScienceVersion $after.opencv.version).Major -ne 5) { throw 'Only OpenCV 5.x is qualified; stopped before package changes.' }
    if ((ConvertTo-ScienceVersion $after.ffmpeg.version).Major -ne 9) { throw 'Only FFmpeg 9.x is qualified; stopped before package changes.' }
    if ([string]$after.opencv.build -notlike 'qt6*' -and [string]$after.opencv.build_string -notlike 'qt6*') { throw 'OpenCV Qt6 is required.' }
    if ([string]$after.ffmpeg.build -notlike 'gpl*' -and [string]$after.ffmpeg.build_string -notlike 'gpl*') { throw 'FFmpeg GPL is required.' }
    foreach($required in @('python','python_abi','spyder','apache-arrow-proc')) {if(-not $after.ContainsKey($required)){throw "Missing qualified foundation: $required"}}
    if([string]$after.python.version -notmatch '^3\.14(?:\.|$)'){throw 'Python 3.14 is required.'}
    if([string]$after.spyder.version -cne '6.1.8'){throw 'Spyder 6.1.8 is required.'}
    if([string]$after.python_abi.build -notmatch '_cp314$'){throw 'Ordinary GIL CPython ABI is required.'}
    if([string]$after['apache-arrow-proc'].build -cne 'cpu'){throw 'CPU Arrow is required.'}
    foreach ($spec in $Packages) {
        $name=Get-ScienceSpecName $spec $script:ScienceRelease.Channels
        if (-not $after.ContainsKey($name)) { throw "Incomplete solution: missing $name before package changes." }
    }
    return $after
}
function Invoke-ScienceNative {
    param([string]$Executable,[string[]]$Arguments,[hashtable]$Environment=@{})
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$Executable
    $psi.Arguments=(@($Arguments | ForEach-Object { ConvertTo-ScienceWindowsArgument $_ }) -join ' ')
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    foreach ($key in @($psi.EnvironmentVariables.Keys)) {
        if ([string]$key -match '^(CONDA_|MAMBA_|PYTHONHOME$|PYTHONPATH$)') { $psi.EnvironmentVariables.Remove([string]$key) }
    }
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[$key]=[string]$Environment[$key] }
    $process=New-Object Diagnostics.Process; $process.StartInfo=$psi
    try {
        if (-not $process.Start()) { throw 'Could not start the transaction process.' }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return @{ExitCode=$process.ExitCode;Stdout=$stdout.GetAwaiter().GetResult();Stderr=$stderr.GetAwaiter().GetResult()}
    } finally { $process.Dispose() }
}
function Invoke-ScienceMambaJson {
    param($Layout,[string[]]$Arguments)
    $envMap=@{MAMBA_ROOT_PREFIX=$Layout.Root;CONDA_PKGS_DIRS=$Layout.Pkgs;TEMP=$Layout.Tmp;TMP=$Layout.Tmp;Path=((Join-Path $Layout.Science 'Library\bin')+';'+$env:Path)}
    $result=Invoke-ScienceNative -Executable $Layout.Micromamba -Arguments $Arguments -Environment $envMap
    if ($result.ExitCode -ne 0) { throw "Micromamba transaction/solve failed (exit $($result.ExitCode)); no blind retry was performed." }
    try { $plan=[regex]::Match($result.Stdout,'(?s)\{.*\}').Value | ConvertFrom-Json }
    catch { throw 'Micromamba did not return valid transaction JSON.' }
    if (-not $plan.success) { throw 'Micromamba did not report success.' }
    return $plan
}
function Set-ScienceAtomicBytes {
    param([string]$Path,[byte[]]$Bytes)
    $stage=$Path+'.science-stage-'+[Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($stage,$Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($stage,$Path,[NullString]::Value) }
        else { [IO.File]::Move($stage,$Path) }
    } finally { if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) } }
}
function Start-ScienceGtkGuard {
    param($Layout,$Records)
    $hook=Join-Path $Layout.Science 'Scripts\.librsvg-pre-unlink.bat'
    if (-not [IO.File]::Exists($hook)) { return $null }
    $approved=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gtk-hooks-approved.json') -Raw | ConvertFrom-Json
    $hash=Get-ScienceFileSha256 $hook
    if ($hash -notin @($approved | ForEach-Object { $_.sha256 })) { throw 'Unreviewed librsvg pre-unlink hook; stopped before package changes.' }
    if (-not $Records.ContainsKey('librsvg')) { throw 'Orphan librsvg hook; stopped before package changes.' }
    $backup=Join-Path $Layout.Tmp ('librsvg-hook-'+[Guid]::NewGuid().ToString('N')+'.original')
    $original=[IO.File]::ReadAllBytes($hook); [IO.File]::WriteAllBytes($backup,$original)
    # This legacy hook only removes an SVG loader and rebuilds a derived cache.
    # Unlink owns/removes the loader file. Rebuild the cache once all DLLs are linked.
    $guard=[Text.Encoding]::ASCII.GetBytes("@echo off`r`nrem Scientific Python V12 r2: defer legacy pixbuf cache maintenance until linking completes.`r`nexit /b 0`r`n")
    Set-ScienceAtomicBytes $hook $guard
    return @{Path=$hook;Original=$original;OriginalHash=$hash;GuardHash=(Get-ScienceFileSha256 $hook);Backup=$backup;Version=$Records.librsvg.version;Build=$Records.librsvg.build}
}
function Stop-ScienceGtkGuard {
    param($Guard,$Layout)
    if (-not $Guard) { return }
    $records=Get-ScienceRecords $Layout.Science
    if ($records.ContainsKey('librsvg') -and $records.librsvg.version -eq $Guard.Version -and $records.librsvg.build -eq $Guard.Build) {
        if (-not [IO.File]::Exists($Guard.Path) -or (Get-ScienceFileSha256 $Guard.Path) -eq $Guard.GuardHash) { Set-ScienceAtomicBytes $Guard.Path $Guard.Original }
        elseif ((Get-ScienceFileSha256 $Guard.Path) -ne $Guard.OriginalHash) { throw 'Unknown hook after transaction; original retained in installer temp.' }
    }
    if ([IO.File]::Exists($Guard.Backup)) { [IO.File]::Delete($Guard.Backup) }
}
function Update-SciencePixbufCache {
    param($Layout)
    $exe=Join-Path $Layout.Science 'Library\bin\gdk-pixbuf-query-loaders.exe'
    if (-not [IO.File]::Exists($exe)) {
        if ((Get-ScienceRecords $Layout.Science).ContainsKey('gdk-pixbuf')) { throw 'Registered GDK Pixbuf executable is missing.' }
        return
    }
    $moduleRoot=Join-Path $Layout.Science 'Library\lib\gdk-pixbuf-2.0\2.10.0'
    $result=Invoke-ScienceNative $exe @('--update-cache') @{Path=((Join-Path $Layout.Science 'Library\bin')+';'+$env:Path);GDK_PIXBUF_MODULEDIR=(Join-Path $moduleRoot 'loaders');GDK_PIXBUF_MODULE_FILE=(Join-Path $moduleRoot 'loaders.cache')}
    if ($result.ExitCode -ne 0 -or -not [IO.File]::Exists((Join-Path $moduleRoot 'loaders.cache'))) { throw 'GDK Pixbuf cache validation failed after linking; no DLLs were copied.' }
    foreach ($svg in @(Get-ChildItem -LiteralPath (Join-Path $moduleRoot 'loaders') -Filter '*svg.dll' -File -ErrorAction SilentlyContinue)) {
        if (-not [IO.File]::ReadAllText((Join-Path $moduleRoot 'loaders.cache')).Contains($svg.Name)) { throw 'SVG loader was not registered in the final cache.' }
    }
}
function Assert-ScienceNotInUse {
    param($Layout)
    if($env:CONDA_PREFIX -and [IO.Path]::GetFullPath($env:CONDA_PREFIX) -ieq [IO.Path]::GetFullPath($Layout.Science)){throw 'Deactivate Science before installing or updating.'}
    foreach($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        if($process.ExecutablePath -and ([string]$process.ExecutablePath).StartsWith($Layout.Science.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Close Science/Spyder/Python processes before installing or updating.'}
    }
}
function Confirm-ScienceTransaction {
    param($Lock,[string]$Identity)
    Show-ScienceTransaction $Lock.approved (Get-ScienceRecords $Lock.prefix)
    Write-Host ('Approved-plan SHA256: '+$Identity)
    return ((Read-Host 'Apply exactly this transaction? [y/N]').Trim() -match '^(?i:y|yes)$')
}
function Invoke-ScienceReviewedTransaction {
    param($Layout,$Before,$Plan,[string]$ConfigPath,[string[]]$RepairNames=@())
    $lock=New-ScienceApprovedLock $Before $Plan $Layout.Science (Get-ScienceFileSha256 $ConfigPath) (Get-ScienceFileSha256 $Layout.Micromamba) $RepairNames
    $identity=Get-ScienceTextDigest ($lock|ConvertTo-Json -Depth 64 -Compress)
    if(-not (Confirm-ScienceTransaction $lock $identity)){throw 'Transaction cancelled; no package commit was started.'}
    $directory=Join-Path $Layout.Tmp ('science-transaction-'+[Guid]::NewGuid().ToString('N'))
    Assert-ScienceTransactionPath $directory;[void][IO.Directory]::CreateDirectory($directory)
    Write-Host ('Transaction evidence: '+$directory)
    $context=@{Guard=$null}
    try {
        $callback={Assert-ScienceNotInUse $Layout;$context.Guard=Start-ScienceGtkGuard $Layout $Before}.GetNewClosure()
        $null=Invoke-ScienceLockedTransaction $Layout $lock $directory $ConfigPath $identity $callback
    } finally {Stop-ScienceGtkGuard $context.Guard $Layout}
    Update-SciencePixbufCache $Layout
}
function Invoke-ScienceEnvironmentSync {
    param($Layout,[string[]]$Packages)
    if(-not $Layout -or -not $Layout.Root -or -not $Layout.Science -or -not $Layout.Micromamba){throw 'A verified installation layout is required.'}
    foreach($path in @($Layout.Root,$Layout.Science,$Layout.Micromamba,$Layout.Tmp,$Layout.Pkgs)){Assert-ScienceTransactionPath $path}
    if([IO.Path]::GetFullPath($Layout.Science) -ine [IO.Path]::GetFullPath((Join-Path $Layout.Root 'envs/science'))){throw 'Unexpected Science prefix.'}
    Assert-ScienceRegularPath $Layout.Micromamba
    if((Get-ScienceFileSha256 $Layout.Micromamba) -cne $script:ScienceRelease.MicromambaSha256){throw 'Unverified Micromamba executable.'}
    Assert-ScienceNotInUse $Layout
    $configPath=Get-ScienceConfigurationPath
    $initialConfigHash=Get-ScienceFileSha256 $configPath
    $effective=Get-ScienceEffectiveRelease
    if(($Packages -join "`n") -cne ($effective.ScientificPackages -join "`n")){throw 'Package requests differ from the active JSON.'}
    $script:ScienceRelease=$effective
    $exclusive=$null
    try {
        $exclusive=[IO.File]::Open((Join-Path $Layout.Root '.science-update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        # Each necessary repair has its own displayed, approved and locked transaction.
        # The main solve happens afterwards, before its separate approval.
        foreach($name in @('libglib','gdk-pixbuf','librsvg')) {
            $before=Get-ScienceRecords $Layout.Science
            if(-not $before.ContainsKey($name)){continue}
            $required=@($before[$name].files|Where-Object {$_ -eq 'Library/bin/glib-2.0-0.dll' -or $_ -eq 'Library/bin/gdk-pixbuf-query-loaders.exe' -or $_ -match '/loaders/.*pixbufloader[-_]svg\.dll$'})
            if(-not @($required|Where-Object {-not [IO.File]::Exists((Join-Path $Layout.Science $_))}).Count){continue}
            $floors=Get-ScienceMediaFloors $before
            # Explicit same-identity relinking repairs payloads without changing the
            # installed package selection. Its native plan is reviewed separately.
            $record=$before[$name];$null=Get-ScienceArtifactName $record
            $repairFile=Join-Path $Layout.Tmp ('science-repair-'+[Guid]::NewGuid().ToString('N')+'.txt')
            try {
                Set-ScienceAtomicBytes $repairFile ([Text.Encoding]::UTF8.GetBytes("@EXPLICIT`n$($record.url)#$($record.sha256)`n"))
                $repair=Invoke-ScienceMambaJson $Layout @('install','--no-rc','-p',$Layout.Science,'-r',$Layout.Root,'--offline','--no-pyc','--json','--file',$repairFile,'--dry-run')
            } finally {if([IO.File]::Exists($repairFile)){[IO.File]::Delete($repairFile)}}
            $null=Assert-SciencePlan $repair $before $floors @('opencv','ffmpeg',$name)
            if((Get-ScienceFileSha256 $configPath) -cne $initialConfigHash){throw 'Configuration changed during planning; start again.'}
            Invoke-ScienceReviewedTransaction $Layout $before $repair $configPath @($name)
        }
        $before=Get-ScienceRecords $Layout.Science;$floors=Get-ScienceMediaFloors $before
        $isInstalled=[IO.Directory]::Exists((Join-Path $Layout.Science 'conda-meta'))
        if([IO.Directory]::Exists($Layout.Science) -and -not $isInstalled){throw 'Existing Science directory has no package metadata; preserve it and investigate.'}
        $verb=if($isInstalled){'update'}else{'create'}
        $arguments=@($verb,'-p',$Layout.Science,'-r',$Layout.Root)+@(Get-ScienceChannelArguments $effective)+@('--no-shortcuts','--no-pyc','--json','--dry-run')
        if($isInstalled){$arguments+='--all'}
        $arguments+=@($Packages)+@("opencv>=$($floors.opencv)","ffmpeg>=$($floors.ffmpeg)")
        Write-Host 'Solving the complete environment before approval...'
        $plan=Invoke-ScienceMambaJson $Layout $arguments
        $null=Assert-SciencePlan $plan $before $floors $Packages
        if((Get-ScienceFileSha256 $configPath) -cne $initialConfigHash){throw 'Configuration changed during planning; start again.'}
        if(-not @(@($plan.actions.LINK)+@($plan.actions.UNLINK)|Where-Object {$null -ne $_}).Count){Write-Host 'The environment already satisfies the resolved requests.';return}
        Invoke-ScienceReviewedTransaction $Layout $before $plan $configPath
        $null=Assert-SciencePlan ([pscustomobject]@{success=$true;actions=$null}) (Get-ScienceRecords $Layout.Science) $floors $Packages
        Write-Host 'Approved package identities and GTK cache checks passed.'
    } finally {if($exclusive){$exclusive.Dispose()}}
}
. (Join-Path $PSScriptRoot 'science-transaction.ps1')
