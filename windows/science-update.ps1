
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
    $torchBackend=Get-SciencePyTorchBackend $Packages
    if($torchBackend -ceq 'conflicting'){throw 'The PyTorch requests specify conflicting backends.'}
    if($torchBackend -cin @('cpu','cuda')){
        $build=[string]$after['pytorch'].build
        if(-not $build.StartsWith($torchBackend,[StringComparison]::Ordinal)){
            throw ('The solver did not select the requested PyTorch backend: '+$torchBackend.ToUpperInvariant())
        }
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
function Save-ScienceMambaFailure {
    param($Layout,[string[]]$Arguments,$Result,[string]$Reason,[string]$Directory,[ValidateSet('failure.json','result.json')][string]$SummaryName='failure.json')
    # Redact all streams, not just argv: native JSON/errors can echo URLs or secrets.
    $secrets=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $sensitive='(?:[A-Za-z0-9_-]*(?:token|password|passwd|secret|credential|api[_-]?key|access[_-]?key|username|user[_-]?name|authorization|auth)[A-Za-z0-9_-]*)'
    for($i=0;$i -lt $Arguments.Count;$i++) {
        if($Arguments[$i] -match ('(?i)^--?'+$sensitive+'$') -and $i+1 -lt $Arguments.Count){[void]$secrets.Add($Arguments[$i+1])}
        if($Arguments[$i] -match ('(?i)^--?'+$sensitive+'=(.*)$')){[void]$secrets.Add($Matches[1])}
    }
    foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if([string]$entry.Key -match ('(?i)^'+$sensitive+'$') -and [string]$entry.Value){[void]$secrets.Add([string]$entry.Value)}
    }
    $text=(@($Arguments)+@([string]$Result.Stdout,[string]$Result.Stderr) -join "`n").Replace('\/','/')
    foreach($match in [regex]::Matches($text,('(?i)\b'+$sensitive+'["'']?\s*[:=]\s*(?<quote>["''])(?<value>.*?)\k<quote>'))) {
        [void]$secrets.Add($match.Groups['value'].Value)
    }
    foreach($match in [regex]::Matches($text,'(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"'']+')) {
        $uri=$null
        if([Uri]::TryCreate($match.Value,[UriKind]::Absolute,[ref]$uri)) {
            foreach($value in @($uri.UserInfo -split ':')+@([regex]::Matches($uri.Query,'[?&][^=&]+=([^&]+)')|ForEach-Object {$_.Groups[1].Value})) {
                if($value){[void]$secrets.Add($value);[void]$secrets.Add([Uri]::UnescapeDataString($value))}
            }
        }
    }
    foreach($pattern in @(
        ('(?i)\b'+$sensitive+'["'']?\s*[:=]\s*["'']?([^\s,"'';&}\]]+)'),
        '(?i)\b(?:Bearer|Basic)\s+([A-Za-z0-9._~+/=-]+)',
        '(?i)/t/([^/\s?"'']+)'
    )) {
        foreach($match in [regex]::Matches($text,$pattern)){[void]$secrets.Add($match.Groups[1].Value)}
    }
    $redact={param([AllowEmptyString()][string]$Value)
        $Value=$Value.Replace('\/','/')
        # Remove whole URLs, including unknown query credentials and signed URLs.
        $Value=[regex]::Replace($Value,'(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"'']+','[REDACTED-URL]')
        $Value=[regex]::Replace($Value,'(?i)/t/[^/\s?"'']+','/t/[REDACTED]')
        foreach($secret in @($secrets|Sort-Object Length -Descending)){if($secret){$Value=$Value.Replace($secret,'[REDACTED]')}}
        return $Value
    }
    if(-not $Directory){$Directory=Join-Path $Layout.Tmp ('science-solver-failure-'+[Guid]::NewGuid().ToString('N'))}
    $directory=[IO.Path]::GetFullPath($Directory)
    Assert-ScienceTransactionPath $directory
    [void][IO.Directory]::CreateDirectory($directory)
    $encoding=New-Object Text.UTF8Encoding($false)
    $summary=[ordered]@{exit_code=$Result.ExitCode;reason=$Reason;arguments=@($Arguments|ForEach-Object {& $redact $_});stdout='stdout.txt';stderr='stderr.txt'}
    [IO.File]::WriteAllText((Join-Path $directory $SummaryName),($summary|ConvertTo-Json -Depth 8),$encoding)
    [IO.File]::WriteAllText((Join-Path $directory 'stdout.txt'),(& $redact ([string]$Result.Stdout)),$encoding)
    [IO.File]::WriteAllText((Join-Path $directory 'stderr.txt'),(& $redact ([string]$Result.Stderr)),$encoding)
    return $directory
}
function Invoke-ScienceMambaJson {
    param($Layout,[string[]]$Arguments)
    $envMap=@{MAMBA_ROOT_PREFIX=$Layout.Root;CONDA_PKGS_DIRS=$Layout.Pkgs;TEMP=$Layout.Tmp;TMP=$Layout.Tmp;Path=((Join-Path $Layout.Science 'Library\bin')+';'+$env:Path)}
    $result=Invoke-ScienceNative -Executable $Layout.Micromamba -Arguments $Arguments -Environment $envMap
    $reason=$null
    if ($result.ExitCode -ne 0) {
        $reason='Micromamba transaction/solve failed'
        if($Arguments -ccontains '--dry-run' -and ($result.Stdout+$result.Stderr) -cmatch '__cuda_arch'){
            $reason='Micromamba could not satisfy the CUDA GPU architecture dependency (__cuda_arch)'
        }
    } else {
        try { $plan=[regex]::Match($result.Stdout,'(?s)\{.*\}').Value | ConvertFrom-Json -ErrorAction Stop }
        catch {$reason='Micromamba did not return valid transaction JSON'}
        if(-not $reason -and -not $plan.success){$reason='Micromamba did not report success'}
    }
    if($reason) {
        try {$diagnostics=Save-ScienceMambaFailure $Layout $Arguments $result $reason}
        catch {throw "$reason (exit $($result.ExitCode)); diagnostic files could not be written. No blind retry was performed."}
        throw "$reason (exit $($result.ExitCode)); diagnostics: $diagnostics . No blind retry was performed."
    }
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
    if(-not (Test-ScienceInteractiveConfiguration)){return $false}
    Show-ScienceTransaction $Lock.approved (Get-ScienceRecords $Lock.prefix)
    Write-Host ('Approved-plan SHA256: '+$Identity)
    return ((Read-Host 'Apply exactly this transaction? [y/N]').Trim() -match '^(?i:y|yes)$')
}
function Confirm-ScienceDependencyRemovals {
    param([string[]]$Names,$Before)
    if(-not (Test-ScienceInteractiveConfiguration)){return $false}
    Write-Host 'Dependency package names that will disappear (not upgrades/replacements):'
    foreach($name in $Names){Write-Host ("  {0} {1} / {2}" -f $name,$Before[$name].version,$Before[$name].build)}
    return ((Read-Host 'Remove exactly these dependency packages? [y/N]').Trim() -match '^(?i:y|yes)$')
}
function Invoke-ScienceReviewedTransaction {
    param($Layout,$Before,$Plan,[string]$ConfigPath,[string[]]$RepairNames=@(),[scriptblock]$OnCommit)
    if(-not (Test-ScienceInteractiveConfiguration)){throw 'Non-interactive package transactions are not permitted.'}
    $removals=@(Get-ScienceRemovalCandidates $Before $Plan $Layout.Science)
    if($removals.Count -and -not (Confirm-ScienceDependencyRemovals $removals $Before)){throw 'Dependency removals cancelled; no package transaction was started.'}
    $lock=New-ScienceApprovedLock $Before $Plan $Layout.Science (Get-ScienceFileSha256 $ConfigPath) (Get-ScienceFileSha256 $Layout.Micromamba) $RepairNames $removals
    $sourceRepairs=Get-ScienceSourceRepairs $Layout $lock.after @($script:ScienceRelease.Channels)
    for($i=0;$i -lt $lock.after.Count;$i++) {
        $record=$lock.after[$i]
        if($sourceRepairs.ContainsKey([string]$record.name)){
            $lock.after[$i]=$record.PSObject.Copy()
            Set-ScienceSourceProperties $lock.after[$i] $sourceRepairs[[string]$record.name]
        }
    }
    $identity=Get-ScienceTextDigest ($lock|ConvertTo-Json -Depth 64 -Compress)
    if(-not (Confirm-ScienceTransaction $lock $identity)){throw 'Transaction cancelled; no package commit was started.'}
    $directory=Join-Path $Layout.Tmp ('science-transaction-'+[Guid]::NewGuid().ToString('N'))
    Assert-ScienceTransactionPath $directory;[void][IO.Directory]::CreateDirectory($directory)
    Write-Host ('Transaction evidence: '+$directory)
    $context=@{Guard=$null}
    try {
        # Keep caller scope: GetNewClosure creates a module that hides our helpers.
        $callback={
            Assert-ScienceNotInUse $Layout
            $context.Guard=Start-ScienceGtkGuard $Layout $Before
            if($OnCommit){& $OnCommit}
        }
        $null=Invoke-ScienceLockedTransaction $Layout $lock $directory $ConfigPath $identity $callback
    } finally {Stop-ScienceGtkGuard $context.Guard $Layout}
    Update-SciencePixbufCache $Layout
}
function Get-SciencePreparedInstallationState {
    param($Layout)
    Assert-ScienceRegularPath $Layout.State
    $state=Read-ScienceJson $Layout.State
    if(-not $state.user_sid -or $state.user_sid -cne $Layout.Sid -or $state.layout_mode -cne $Layout.Mode -or
        $state.root -ine $Layout.Root -or $state.micromamba -ine $Layout.Micromamba){
        throw 'The preparation state does not identify this user, layout and Micromamba root.'
    }
    return $state
}
function Assert-ScienceOwnedPrefix {
    param($Layout,$State)
    $marker=Join-Path $Layout.Science '.science-environment-owner'
    Assert-ScienceRegularPath $marker
    $ownership=Read-ScienceJson $marker
    if($State.science_owner_id -cnotmatch '^[0-9a-f]{32}$' -or $ownership.id -cne $State.science_owner_id -or
        $ownership.sid -cne $Layout.Sid -or $ownership.prefix -ine $Layout.Science){
        throw 'The selected Science prefix lacks matching environment ownership evidence.'
    }
}
function Assert-ScienceRecordedPrefix {
    param($Layout,$Installed)
    $manifest=Read-ScienceJson (Join-Path $Layout.Root 'science-packages.json')
    $recorded=@(foreach($row in $manifest.packages){
        [pscustomobject]@{name=$row.name;version=$row.version;build=$row.build_string;subdir=$row.platform;sha256=$row.sha256}
    })
    if(-not $Installed.Count -or (Get-ScienceRecordSignature $recorded) -cne (Get-ScienceRecordSignature @($Installed.Values))){
        throw 'The existing Science prefix differs from its last verified package manifest.'
    }
}
function Find-ScienceApprovedRecovery {
    param($Layout,$Installed,[string]$ConfigHash)
    if(-not $Installed.Count){return $null}
    $identity=Get-ScienceRecordSignature @($Installed.Values)
    $exeHash=Get-ScienceFileSha256 $Layout.Micromamba
    $directories=Get-ChildItem -LiteralPath $Layout.Tmp -Filter 'science-transaction-*' -Directory | Sort-Object LastWriteTimeUtc -Descending
    foreach($directory in $directories) {
        if($directory.Name -cnotmatch '^science-transaction-[0-9a-f]{32}$'){continue}
        try {
            $path=Join-Path $directory.FullName 'approved-lock.json'
            Assert-ScienceTransactionPath $directory.FullName
            Assert-ScienceRegularPath $path
            $lock=Read-ScienceJson $path
            if($lock.schema -eq 1 -and $lock.prefix -ieq $Layout.Science -and $lock.config_sha256 -ceq $ConfigHash -and
                $lock.executable_sha256 -ceq $exeHash -and (Get-ScienceRecordSignature @($lock.after)) -ceq $identity) {
                return $directory.Name
            }
        } catch {
            # Incomplete or redirected evidence cannot authorize recovery.
            continue
        }
    }
    return $null
}
function Repair-ScienceInstalledSources {
    param($Layout,$Before,[string[]]$Channels,[string]$ConfigPath,[string]$ConfigHash)
    $prefixDigest=Get-SciencePrefixDigest $Layout.Science
    $sourceRepairs=Get-ScienceSourceRepairs $Layout @($Before.Values) $Channels
    if(-not $sourceRepairs.Count){return}
    if(-not (Test-ScienceInteractiveConfiguration)){throw 'Package-source restoration requires an interactive console.'}
    Write-Host ('Verified package sources: '+(@($sourceRepairs.Keys|Sort-Object) -join ', '))
    if((Read-Host 'Restore the verified conda-forge sources for these installed packages? [y/N]').Trim() -notmatch '^(?i:y|yes)$'){
        throw 'Package-source restoration was cancelled.'
    }
    Assert-ScienceNotInUse $Layout
    if((Get-SciencePrefixDigest $Layout.Science) -cne $prefixDigest -or (Get-ScienceFileSha256 $ConfigPath) -cne $ConfigHash){
        throw 'Installed package metadata or configuration changed before source restoration.'
    }
    $metadata=Join-Path $Layout.Science 'conda-meta'
    foreach($file in Get-ChildItem -LiteralPath $metadata -Filter '*.json' -File){
        Assert-ScienceRegularPath $file.FullName
        $record=Read-ScienceJson $file.FullName
        if($sourceRepairs.ContainsKey([string]$record.name)){
            Set-ScienceSourceProperties $record $sourceRepairs[[string]$record.name]
            Write-ScienceTransactionJson $file.FullName $record
        }
    }
    $final=Get-ScienceRecords $Layout.Science
    if((Get-ScienceRecordSignature @($final.Values)) -cne (Get-ScienceRecordSignature @($Before.Values))){throw 'Installed identities changed during source restoration.'}
    foreach($name in $sourceRepairs.Keys){
        if($final[$name].url -cne $sourceRepairs[$name].url -or $final[$name].fn -cne $sourceRepairs[$name].fn){
            throw "Package-source restoration failed: $name"
        }
    }
}
function Invoke-ScienceEnvironmentSync {
    param($Layout,[string[]]$Packages,[scriptblock]$AfterSync)
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
    $torchBackend=Get-SciencePyTorchBackend $Packages
    if($torchBackend -ceq 'cuda'){
        if(-not (Test-ScienceNvidiaDevice)){
            throw 'PyTorch CUDA requires a working NVIDIA driver and a detectable GPU.'
        }
        $info=Invoke-ScienceNative $Layout.Micromamba @('info','--no-rc','-r',$Layout.Root,'--json') @{MAMBA_ROOT_PREFIX=$Layout.Root;CONDA_PKGS_DIRS=$Layout.Pkgs}
        if($info.ExitCode -ne 0){throw 'Could not verify CUDA compatibility in Micromamba.'}
        $virtual=(ConvertFrom-ScienceTransactionJson $info.Stdout).'virtual packages'
        if(-not ($virtual -cmatch '^__cuda=[1-9]\d*(?:\.\d+)*=0$')){
            throw 'Micromamba did not detect a compatible CUDA driver for dependency solving.'
        }
    }
    if($torchBackend -cin @('cpu','cuda')){
        Write-Host ('PyTorch backend requested: '+$torchBackend.ToUpperInvariant()+'.')
    }
    $exclusive=$null
    try {
        $lockPath=Join-Path $Layout.Root '.science-update.lock'
        Assert-ScienceTransactionPath $lockPath
        $exclusive=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if($AfterSync) {
            $state=Get-SciencePreparedInstallationState $Layout
            $onCommit={
                $null=Get-SciencePreparedInstallationState $Layout
                $state|Add-Member -NotePropertyName finalization_stage -NotePropertyValue 'package-commit' -Force
                Write-ScienceTransactionJson $Layout.State $state
            }
            if([IO.Directory]::Exists($Layout.Science)){
                if($state.science_owner_id){Assert-ScienceOwnedPrefix $Layout $state}
                if($state.finalization_stage -cne 'complete' -or -not $state.science_owner_id){
                    $before=Get-ScienceRecords $Layout.Science
                    $evidence=Find-ScienceApprovedRecovery $Layout $before $initialConfigHash
                    if($evidence) {
                        $recoveryDigest=Get-SciencePrefixDigest $Layout.Science
                        $null=Assert-SciencePlan ([pscustomobject]@{success=$true;actions=$null}) $before (Get-ScienceMediaFloors $before) $Packages
                        if(-not (Test-ScienceInteractiveConfiguration)){throw 'Interrupted installation finalization requires an interactive console.'}
                        Write-Host ('Installed package identities match the approved transaction: '+$evidence)
                        if((Read-Host 'Finish installation using those installed packages? [y/N]').Trim() -notmatch '^(?i:y|yes)$'){
                            throw 'Interrupted installation finalization was cancelled.'
                        }
                        Assert-ScienceNotInUse $Layout
                        if((Get-SciencePrefixDigest $Layout.Science) -cne $recoveryDigest -or (Get-ScienceFileSha256 $configPath) -cne $initialConfigHash){
                            throw 'Approved recovery inputs changed.'
                        }
                        Repair-ScienceInstalledSources $Layout $before @($effective.Channels) $configPath $initialConfigHash
                        Update-SciencePixbufCache $Layout
                        & $AfterSync $state $evidence
                        return
                    }
                    if(-not $state.science_owner_id){
                        if(-not $state.last_sync_utc){throw 'The existing Science prefix has no completed installer state or matching approved transaction.'}
                        Assert-ScienceRecordedPrefix $Layout $before
                    }
                }
            }
        }
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
            Invoke-ScienceReviewedTransaction $Layout $before $repair $configPath @($name) -OnCommit $onCommit
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
        $after=Assert-SciencePlan $plan $before $floors $Packages
        if($torchBackend -cin @('cpu','cuda')){
            $torch=$after['pytorch']
            Write-Host ("PyTorch {0}: {1} ({2})" -f $torchBackend.ToUpperInvariant(),$torch.version,$torch.build)
        }
        if((Get-ScienceFileSha256 $configPath) -cne $initialConfigHash){throw 'Configuration changed during planning; start again.'}
        if(-not @(@($plan.actions.LINK)+@($plan.actions.UNLINK)|Where-Object {$null -ne $_}).Count){
            Repair-ScienceInstalledSources $Layout $before @($effective.Channels) $configPath $initialConfigHash
            if($AfterSync){
                $finalizationDigest=Get-SciencePrefixDigest $Layout.Science
                if(-not (Test-ScienceInteractiveConfiguration) -or (Read-Host 'Verify and refresh Science installer state and launchers? [y/N]').Trim() -notmatch '^(?i:y|yes)$'){
                    throw 'Finalization was cancelled.'
                }
                Assert-ScienceNotInUse $Layout
                if((Get-SciencePrefixDigest $Layout.Science) -cne $finalizationDigest -or (Get-ScienceFileSha256 $configPath) -cne $initialConfigHash){
                    throw 'Approved finalization inputs changed.'
                }
                & $AfterSync $state $null
            }
            Write-Host 'The environment already satisfies the resolved requests.'
            return
        }
        Invoke-ScienceReviewedTransaction $Layout $before $plan $configPath -OnCommit $onCommit
        $null=Assert-SciencePlan ([pscustomobject]@{success=$true;actions=$null}) (Get-ScienceRecords $Layout.Science) $floors $Packages
        Write-Host 'Approved package identities and GTK cache checks passed.'
        if($AfterSync){& $AfterSync $state $null}
    } finally {if($exclusive){$exclusive.Dispose()}}
}
. (Join-Path $PSScriptRoot 'science-transaction.ps1')
