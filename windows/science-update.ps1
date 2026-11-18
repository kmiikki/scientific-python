
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot

# Trace only fixed stage labels, counts and exception types. Never write raw
# exceptions, package URLs, arguments, or configuration data into this log.
function New-ScienceUpdateTrace {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('scientific-python-update-'+[Guid]::NewGuid().ToString('N')+'.log')
    try {
        $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $file.Dispose()
        Write-Host "Update phase log: $path"
        return @{Path=$path;Step=$null;Last='none';Clock=$null}
    } catch {
        Write-Warning 'Could not create the update phase log; console status is still available.'
        return @{Path=$null;Step=$null;Last='none';Clock=$null}
    }
}
function Write-ScienceUpdateTrace {
    param($Trace,[string]$Message)
    if(-not $Trace){return}
    Write-Host "[Update] $Message"
    if($Trace.Path){
        try{[IO.File]::AppendAllText($Trace.Path,([DateTime]::UtcNow.ToString('o')+' '+$Message+[Environment]::NewLine))}
        catch{$Trace.Path=$null;Write-Warning 'Could not append to the update phase log.'}
    }
}
function Complete-ScienceUpdatePhase {
    param($Trace)
    if(-not $Trace -or -not $Trace.Step){return}
    $Trace.Last=$Trace.Step
    Write-ScienceUpdateTrace $Trace ('DONE {0} ({1:0.00} s)' -f $Trace.Step,$Trace.Clock.Elapsed.TotalSeconds)
    $Trace.Step=$null
}
function Start-ScienceUpdatePhase {
    param($Trace,[string]$Stage)
    if(-not $Trace){return}
    Complete-ScienceUpdatePhase $Trace
    $Trace.Step=$Stage
    $Trace.Clock=[Diagnostics.Stopwatch]::StartNew()
    Write-ScienceUpdateTrace $Trace ("START $Stage")
}
function Stop-ScienceUpdatePhase {
    param($Trace,$Failure)
    if(-not $Trace -or -not $Trace.Step){return}
    $errorType=if($Failure){$Failure.Exception.GetType().Name}else{'CheckFailed'}
    Write-ScienceUpdateTrace $Trace ('FAIL {0} ({1:0.00} s); type={2}; last completed={3}' -f $Trace.Step,$Trace.Clock.Elapsed.TotalSeconds,$errorType,$Trace.Last)
    $Trace.Step=$null
}

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
    $started=$false
    try {
        if (-not $process.Start()) { throw 'Could not start the transaction process.' }
        $started=$true
        $packagePhase=($Arguments -ccontains '--offline' -and $Arguments -ccontains '--file' -and $Arguments -ccontains '--json')
        if ($packagePhase) {
            $buffers=@([pscustomobject]@{Reader=$process.StandardOutput; Data=(New-Object char[] 8192); Text=(New-Object Text.StringBuilder); Task=$null; Overflow=$false},
                       [pscustomobject]@{Reader=$process.StandardError; Data=(New-Object char[] 8192); Text=(New-Object Text.StringBuilder); Task=$null; Overflow=$false})
            foreach($buffer in $buffers){$buffer.Task=$buffer.Reader.ReadAsync($buffer.Data,0,$buffer.Data.Length)}
            $clock=[Diagnostics.Stopwatch]::StartNew();$next=5;$limit=32MB
            while ($null -ne $buffers[0].Task -or $null -ne $buffers[1].Task -or -not $process.HasExited) {
                foreach($buffer in $buffers){
                    if($null -eq $buffer.Task -or -not $buffer.Task.IsCompleted){continue}
                    $count=$buffer.Task.GetAwaiter().GetResult()
                    if($count -eq 0){$buffer.Task=$null;continue}
                    $keep=[Math]::Min($count,$limit-$buffer.Text.Length)
                    if($keep -gt 0){[void]$buffer.Text.Append($buffer.Data,0,$keep)}
                    if($keep -lt $count){$buffer.Overflow=$true}
                    $buffer.Task=$buffer.Reader.ReadAsync($buffer.Data,0,$buffer.Data.Length)
                }
                if($clock.Elapsed.TotalSeconds -ge $next -and -not $process.HasExited){
                    Write-Host ('[6/9] Installing packages  RUNNING  Elapsed: '+$clock.Elapsed.ToString('hh\:mm\:ss')+'  Micromamba process: ACTIVE')
                    $next=$clock.Elapsed.TotalSeconds+5
                }
                if($clock.Elapsed.TotalMinutes -ge 30){throw 'Micromamba did not finish within 30 minutes. Check the interrupted transaction and do not retry blindly.'}
                if(-not (($null -ne $buffers[0].Task -and $buffers[0].Task.IsCompleted) -or ($null -ne $buffers[1].Task -and $buffers[1].Task.IsCompleted))){Start-Sleep -Milliseconds 25}
            }
            $exit=$process.ExitCode
            $err=$buffers[1].Text.ToString()
            if($buffers[0].Overflow -or $buffers[1].Overflow){
                if($exit -eq 0){$exit=1}
                return @{ExitCode=$exit;Stdout='';Stderr=($err+"`nCapture limit exceeded (native exit $($process.ExitCode)); transaction output cannot be verified.")}
            }
            return @{ExitCode=$exit;Stdout=$buffers[0].Text.ToString();Stderr=$err}
        }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return @{ExitCode=$process.ExitCode;Stdout=$stdout.GetAwaiter().GetResult();Stderr=$stderr.GetAwaiter().GetResult()}
    } finally {
        if($started -and -not $process.HasExited){try {$process.Kill();[void]$process.WaitForExit(5000)} catch {Write-Warning 'Could not confirm interruption of the Micromamba process.'}}
        $process.Dispose()
    }
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
    param($Layout,[string[]]$Arguments,[hashtable]$CudaOverrides=@{},[string[]]$CudaRetryArguments=@())
    $envMap=@{MAMBA_ROOT_PREFIX=$Layout.Root;CONDA_PKGS_DIRS=$Layout.Pkgs;TEMP=$Layout.Tmp;TMP=$Layout.Tmp;Path=((Join-Path $Layout.Science 'Library\bin')+';'+$env:Path)}
    foreach($name in $CudaOverrides.Keys){$envMap[$name]=$CudaOverrides[$name]}
    $result=Invoke-ScienceNative -Executable $Layout.Micromamba -Arguments $Arguments -Environment $envMap
    if($result.ExitCode -ne 0 -and $CudaRetryArguments.Count){
        $conflicts=@()
        try {$conflicts=@((ConvertFrom-ScienceTransactionJson $result.Stdout).solver_problems)}
        catch {}
        if($conflicts -match '\bcuda-version\b'){
            Write-Host 'Checking CUDA 13 minor-version compatibility with the same scientific package constraints.'
            $Arguments=$CudaRetryArguments
            $result=Invoke-ScienceNative -Executable $Layout.Micromamba -Arguments $Arguments -Environment $envMap
        }
    }
    $reason=$null
    if ($result.ExitCode -ne 0) {
        $reason='Micromamba transaction/solve failed'
        if($Arguments -ccontains '--dry-run' -and ($result.Stdout+$result.Stderr) -cmatch '__cuda_arch'){
            $reason='Micromamba could not satisfy __cuda_arch for the available packages. Use a verified Micromamba release with CEP 46 support or a compatible conda-forge CUDA build'
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
    param($Layout,$Before,$Plan,[string]$ConfigPath,[string[]]$RepairNames=@(),[scriptblock]$OnCommit,[hashtable]$CudaOverrides=@{})
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
        $null=Invoke-ScienceLockedTransaction $Layout $lock $directory $ConfigPath $identity $callback -CudaOverrides $CudaOverrides
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
    param($Layout,$Installed,[string]$ConfigHash,$Trace)
    if(-not $Installed.Count){return $null}
    $identity=Get-ScienceRecordSignature @($Installed.Values)
    $exeHash=Get-ScienceFileSha256 $Layout.Micromamba
    $directories=@(Get-ChildItem -LiteralPath $Layout.Tmp -Filter 'science-transaction-*' -Directory | Sort-Object LastWriteTimeUtc -Descending)
    $candidate=0
    $nextUpdate=0
    $unusable=0
    foreach($directory in $directories) {
        if($directory.Name -cnotmatch '^science-transaction-[0-9a-f]{32}$'){continue}
        $candidate++
        try {
            $path=Join-Path $directory.FullName 'approved-lock.json'
            Assert-ScienceTransactionPath $directory.FullName
            Assert-ScienceRegularPath $path
            $bytes=([IO.FileInfo]::new($path)).Length
            if($Trace -and ($bytes -ge 8MB -or $Trace.Clock.Elapsed.TotalSeconds -ge $nextUpdate)){
                Write-ScienceUpdateTrace $Trace ('Recovery evidence: checking file {0} of {1}, {2} bytes' -f $candidate,$directories.Count,$bytes)
                $nextUpdate=$Trace.Clock.Elapsed.TotalSeconds+5
            }
            $readClock=[Diagnostics.Stopwatch]::StartNew()
            $lock=Read-ScienceJson $path
            if($readClock.Elapsed.TotalSeconds -ge 5){
                Write-ScienceUpdateTrace $Trace ('Recovery evidence: parsed file {0} in {1:0.00} s' -f $candidate,$readClock.Elapsed.TotalSeconds)
            }
            if($lock.schema -eq 1 -and $lock.prefix -ieq $Layout.Science -and $lock.config_sha256 -ceq $ConfigHash -and
                $lock.executable_sha256 -ceq $exeHash -and (Get-ScienceRecordSignature @($lock.after)) -ceq $identity) {
                Write-ScienceUpdateTrace $Trace ('Recovery evidence: exact identity match in file {0}; unusable files so far: {1}.' -f $candidate,$unusable)
                return $directory.Name
            }
        } catch {
            # Incomplete or redirected evidence cannot authorize recovery.
            $unusable++
            if($Trace -and $Trace.Clock.Elapsed.TotalSeconds -ge $nextUpdate){
                Write-ScienceUpdateTrace $Trace ('Recovery evidence: unusable file {0}; type={1}' -f $candidate,$_.Exception.GetType().Name)
                $nextUpdate=$Trace.Clock.Elapsed.TotalSeconds+5
            }
            continue
        }
    }
    Write-ScienceUpdateTrace $Trace ('Recovery evidence: no exact match in {0} candidates; {1} incomplete, unsafe or invalid.' -f $candidate,$unusable)
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
function Get-ScienceNvidiaCudaHardware {
    $nvidia=Get-Command nvidia-smi.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $nvidia){throw 'PyTorch CUDA requires nvidia-smi and a working NVIDIA driver.'}
    $driver=Invoke-ScienceNative $nvidia.Source @('--query','-u','-x')
    $devices=Invoke-ScienceNative $nvidia.Source @('--query-gpu=compute_cap','--format=csv,noheader')
    $versionMatches=[regex]::Matches($driver.Stdout,'<cuda_version>\s*([1-9]\d*\.\d+)\s*</cuda_version>')
    $releaseMatches=[regex]::Matches($driver.Stdout,'<driver_version>\s*([1-9]\d*(?:\.\d+){1,3})\s*</driver_version>')
    $capabilities=@($devices.Stdout.Trim() -split '\r?\n' | ForEach-Object {$_.Trim()})
    if($driver.ExitCode -ne 0 -or $devices.ExitCode -ne 0 -or $versionMatches.Count -ne 1 -or $releaseMatches.Count -ne 1 -or
        -not $capabilities.Count -or @($capabilities|Where-Object {$_ -cnotmatch '^[1-9]\d*\.\d+$'}).Count){
        throw 'The NVIDIA driver capability and GPU compute capability could not be verified.'
    }
    $architecture=$capabilities|Sort-Object {[version]$_}|Select-Object -First 1
    return [pscustomobject]@{
        Driver=$versionMatches[0].Groups[1].Value;Architecture=$architecture
        DriverRelease=$releaseMatches[0].Groups[1].Value
    }
}
function Get-ScienceCudaVirtualPackages {
    param($Layout,[hashtable]$Overrides=@{})
    $environment=@{MAMBA_ROOT_PREFIX=$Layout.Root;CONDA_PKGS_DIRS=$Layout.Pkgs}
    foreach($name in $Overrides.Keys){$environment[$name]=$Overrides[$name]}
    $info=Invoke-ScienceNative $Layout.Micromamba @('info','--no-rc','-r',$Layout.Root,'--json') $environment
    if($info.ExitCode -ne 0){throw 'Could not verify CUDA compatibility in Micromamba.'}
    $result=@{}
    foreach($row in (ConvertFrom-ScienceTransactionJson $info.Stdout).'virtual packages'){
        if($row -cmatch '^(__cuda|__cuda_arch)=([1-9]\d*\.\d+)=0$'){
            $name=$Matches[1]
            if($result.ContainsKey($name)){throw 'Micromamba reported ambiguous CUDA virtual packages.'}
            $result[$name]=$Matches[2]
        }
    }
    return $result
}
function Get-ScienceCudaSolverSettings {
    param($Layout)
    $hardware=Get-ScienceNvidiaCudaHardware
    $driver=$hardware.Driver
    $architecture=$hardware.Architecture
    $native=Get-ScienceCudaVirtualPackages $Layout
    $overrides=@{}
    if($native['__cuda'] -cne $driver){$overrides['CONDA_OVERRIDE_CUDA']=$driver}
    if($native['__cuda_arch'] -cne $architecture){
        if($native.ContainsKey('__cuda_arch')){throw 'Micromamba GPU architecture disagrees with the detected hardware.'}
        $overrides['CONDA_OVERRIDE_CUDA_ARCH']=$architecture
    }
    if($overrides.Count){
        $verified=Get-ScienceCudaVirtualPackages $Layout $overrides
        if($verified['__cuda'] -cne $driver){throw 'Micromamba could not verify the NVIDIA driver CUDA capability.'}
        if(-not $verified.ContainsKey('__cuda_arch')){
            $overrides.Remove('CONDA_OVERRIDE_CUDA_ARCH')
            Write-Host 'Micromamba lacks __cuda_arch. The selected cuda-arch package minimum will be checked against the GPU.'
        }
        elseif($verified['__cuda_arch'] -cne $architecture){
            throw 'Micromamba returned a CUDA architecture different from the verified hardware.'
        }
    }
    $driverVersion=[version]$driver
    # NVIDIA documents CUDA 13 minor compatibility for R580 and newer.
    $minorLimit=if($driverVersion.Major -eq 13 -and ([version]$hardware.DriverRelease).Major -ge 580){'14.0'}else{$null}
    Write-Host "NVIDIA driver CUDA $driver; minimum detected GPU compute capability $architecture."
    if($overrides.Count){
        $detail=@($overrides.Keys|Sort-Object|ForEach-Object {"$_=$($overrides[$_])"}) -join ', '
        Write-Host "Using verified hardware values in Micromamba subprocesses: $detail"
    }
    return [pscustomobject]@{
        Driver=$driver;Architecture=$architecture
        RuntimeLimit="$($driverVersion.Major).$($driverVersion.Minor+1)";MinorLimit=$minorLimit;Overrides=$overrides
    }
}
function Assert-ScienceCudaSolution {
    param($After,$Cuda)
    $runtime=$After['cuda-version']
    $minimum=$After['cuda-arch'].version
    if(-not $minimum -or (ConvertTo-ScienceVersion $minimum) -gt (ConvertTo-ScienceVersion $Cuda.Architecture)){
        throw 'The planned CUDA packages lack a verified compatible GPU compute capability.'
    }
    if(-not $runtime.version){throw 'The planned CUDA packages lack a runtime version record.'}
    if((ConvertTo-ScienceVersion $runtime.version) -lt (ConvertTo-ScienceVersion $Cuda.RuntimeLimit)){return $false}
    if(-not $Cuda.MinorLimit -or (ConvertTo-ScienceVersion $runtime.version) -ge (ConvertTo-ScienceVersion $Cuda.MinorLimit) -or
        $runtime.url -cnotmatch '^https://conda\.anaconda\.org/conda-forge/(?:win-64|noarch)/cuda-version-[^/?#]+$' -or
        $runtime.constrains -cnotcontains '__cuda >=13'){
        throw 'The planned CUDA runtime exceeds the verified driver capability.'
    }
    return $true
}
function Invoke-ScienceEnvironmentSync {
    param($Layout,[string[]]$Packages,[scriptblock]$AfterSync,$Trace)
    $exclusive=$null
    try {
        Start-ScienceUpdatePhase $Trace 'Layout and executable verification'
        if(-not $Layout -or -not $Layout.Root -or -not $Layout.Science -or -not $Layout.Micromamba){throw 'A verified installation layout is required.'}
        foreach($path in @($Layout.Root,$Layout.Science,$Layout.Micromamba,$Layout.Tmp,$Layout.Pkgs)){Assert-ScienceTransactionPath $path}
        if([IO.Path]::GetFullPath($Layout.Science) -ine [IO.Path]::GetFullPath((Join-Path $Layout.Root 'envs/science'))){throw 'Unexpected Science prefix.'}
        Assert-ScienceRegularPath $Layout.Micromamba
        if((Get-ScienceFileSha256 $Layout.Micromamba) -cne $script:ScienceRelease.MicromambaSha256){throw 'Unverified Micromamba executable.'}
        Start-ScienceUpdatePhase $Trace 'Process usage check'
        Assert-ScienceNotInUse $Layout
        Start-ScienceUpdatePhase $Trace 'Configuration and solver options'
        $configPath=Get-ScienceConfigurationPath
        $initialConfigHash=Get-ScienceFileSha256 $configPath
        $effective=Get-ScienceEffectiveRelease
        if(($Packages -join "`n") -cne ($effective.ScientificPackages -join "`n")){throw 'Package requests differ from the active JSON.'}
        $script:ScienceRelease=$effective
        $torchBackend=Get-SciencePyTorchBackend $Packages
        $cuda=$null
        $cudaArgs=@{}
        if($torchBackend -ceq 'cuda'){
            $cuda=Get-ScienceCudaSolverSettings $Layout
            if($cuda.Overrides.Count){$cudaArgs['CudaOverrides']=$cuda.Overrides}
        }
        if($torchBackend -cin @('cpu','cuda')){
            Write-Host ('PyTorch backend requested: '+$torchBackend.ToUpperInvariant()+'.')
        }
        Start-ScienceUpdatePhase $Trace 'Update lock'
        $lockPath=Join-Path $Layout.Root '.science-update.lock'
        Assert-ScienceTransactionPath $lockPath
        $exclusive=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if($AfterSync) {
            Start-ScienceUpdatePhase $Trace 'Prepared state and prefix ownership'
            $state=Get-SciencePreparedInstallationState $Layout
            $onCommit={
                $null=Get-SciencePreparedInstallationState $Layout
                $state|Add-Member -NotePropertyName finalization_stage -NotePropertyValue 'package-commit' -Force
                Write-ScienceTransactionJson $Layout.State $state
            }
            if([IO.Directory]::Exists($Layout.Science)){
                if($state.science_owner_id){Assert-ScienceOwnedPrefix $Layout $state}
                if($state.finalization_stage -cne 'complete' -or -not $state.science_owner_id){
                    Start-ScienceUpdatePhase $Trace 'Installed identities for legacy or interrupted update'
                    $before=Get-ScienceRecords $Layout.Science
                    Start-ScienceUpdatePhase $Trace 'Approved transaction evidence'
                    $evidence=Find-ScienceApprovedRecovery $Layout $before $initialConfigHash $Trace
                    if($evidence) {
                        Start-ScienceUpdatePhase $Trace 'Approved recovery snapshot and review'
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
                        Start-ScienceUpdatePhase $Trace 'Approved recovery source verification and finalization'
                        Repair-ScienceInstalledSources $Layout $before @($effective.Channels) $configPath $initialConfigHash
                        if($cuda){$null=Assert-ScienceCudaSolution (Get-ScienceRecords $Layout.Science) $cuda}
                        Update-SciencePixbufCache $Layout
                        & $AfterSync $state $evidence
                        Complete-ScienceUpdatePhase $Trace
                        return
                    }
                    if(-not $state.science_owner_id){
                        Start-ScienceUpdatePhase $Trace 'Last verified package manifest'
                        if(-not $state.last_sync_utc){throw 'The existing Science prefix has no completed installer state or matching approved transaction.'}
                        Assert-ScienceRecordedPrefix $Layout $before
                    }
                }
            }
        }
        # Each necessary repair has its own displayed, approved and locked transaction.
        # The main solve happens afterwards, before its separate approval.
        Start-ScienceUpdatePhase $Trace 'GTK payload and repair preflight'
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
            Invoke-ScienceReviewedTransaction $Layout $before $repair $configPath @($name) -OnCommit $onCommit @cudaArgs
        }
        Start-ScienceUpdatePhase $Trace 'Package solver inputs'
        $before=Get-ScienceRecords $Layout.Science;$floors=Get-ScienceMediaFloors $before
        $isInstalled=[IO.Directory]::Exists((Join-Path $Layout.Science 'conda-meta'))
        if([IO.Directory]::Exists($Layout.Science) -and -not $isInstalled){throw 'Existing Science directory has no package metadata; preserve it and investigate.'}
        $verb=if($isInstalled){'update'}else{'create'}
        $arguments=@($verb,'-p',$Layout.Science,'-r',$Layout.Root)+@(Get-ScienceChannelArguments $effective)+@('--no-shortcuts','--no-pyc','--json','--dry-run')
        if($isInstalled){$arguments+='--all'}
        $arguments+=@($Packages)+@("opencv>=$($floors.opencv)","ffmpeg>=$($floors.ffmpeg)")
        Write-Host 'Solving the complete environment before approval...'
        Start-ScienceUpdatePhase $Trace 'Micromamba solver dry run'
        $solveArgs=$cudaArgs.Clone()
        $solveArguments=$arguments
        if($cuda -and @($Packages|Where-Object {(Get-ScienceSpecName $_) -ceq 'cuda-version'}).Count -eq 0){
            if($cuda.MinorLimit){$solveArgs['CudaRetryArguments']=$arguments+@("cuda-version<$($cuda.MinorLimit)")}
            $solveArguments+="cuda-version<$($cuda.RuntimeLimit)"
        }
        $plan=Invoke-ScienceMambaJson $Layout $solveArguments @solveArgs
        Start-ScienceUpdatePhase $Trace 'Solver result verification'
        $after=Assert-SciencePlan $plan $before $floors $Packages
        if($cuda){
            $minor=Assert-ScienceCudaSolution $after $cuda
            $plan|Add-Member -NotePropertyName cuda_compatibility -NotePropertyValue ([ordered]@{
                driver=$cuda.Driver;gpu_compute_capability=$cuda.Architecture;runtime=$after['cuda-version'].version
                minimum_compute_capability=$after['cuda-arch'].version;minor_version_compatibility=$minor
            })
            if($minor){
                Write-Host ("CUDA {0} uses NVIDIA minor-version compatibility with driver CUDA {1}. New driver features and PTX JIT can require a newer driver. Review this limitation before approving; GPU execution is checked after installation." -f $after['cuda-version'].version,$cuda.Driver)
            }
        }
        if($torchBackend -cin @('cpu','cuda')){
            $torch=$after['pytorch']
            Write-Host ("PyTorch {0}: {1} ({2})" -f $torchBackend.ToUpperInvariant(),$torch.version,$torch.build)
        }
        if((Get-ScienceFileSha256 $configPath) -cne $initialConfigHash){throw 'Configuration changed during planning; start again.'}
        if(-not @(@($plan.actions.LINK)+@($plan.actions.UNLINK)|Where-Object {$null -ne $_}).Count){
            Start-ScienceUpdatePhase $Trace 'No-change source verification and finalization review'
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
            Complete-ScienceUpdatePhase $Trace
            return
        }
        Start-ScienceUpdatePhase $Trace 'Package transaction review and execution if approved'
        Invoke-ScienceReviewedTransaction $Layout $before $plan $configPath -OnCommit $onCommit @cudaArgs
        Start-ScienceUpdatePhase $Trace 'Installed identities and finalization'
        $null=Assert-SciencePlan ([pscustomobject]@{success=$true;actions=$null}) (Get-ScienceRecords $Layout.Science) $floors $Packages
        Write-Host 'Approved package identities and GTK cache checks passed.'
        if($AfterSync){& $AfterSync $state $null}
        Complete-ScienceUpdatePhase $Trace
    } catch {
        Stop-ScienceUpdatePhase $Trace $_
        throw
    } finally {if($exclusive){$exclusive.Dispose()}}
}
. (Join-Path $PSScriptRoot 'science-transaction.ps1')
