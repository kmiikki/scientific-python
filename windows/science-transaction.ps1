# Approved-plan execution for Micromamba 2.10.0. No dependency solver is implemented here.
# A verified local channel contains exactly the approved final universe; every native
# preflight/commit is compared with the approved LINK/UNLINK identities.
function Assert-ScienceTransactionPath {
    param([string]$Path)
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw "Redirected transaction path: $Path"}
        }
        $next=Split-Path -Parent $cursor
        if ($next -eq $cursor) {break};$cursor=$next
    }
}
function Get-ScienceTextDigest {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
}
function Get-ScienceIdentity {
    param($Record)
    foreach($field in @('name','version','build')) {
        if ([string]$Record.$field -cnotmatch '^[A-Za-z0-9_.+!-]+$') {throw "Invalid package identity $field"}
    }
    if (@('win-64','noarch') -cnotcontains [string]$Record.subdir -or [string]$Record.sha256 -cnotmatch '^[0-9a-f]{64}$') {throw "Missing/invalid platform or SHA256 identity: $($Record.name)"}
    return (@($Record.name,$Record.version,$Record.build,$Record.subdir,$Record.sha256) -join '|')
}
function Get-ScienceRecordSignature {
    param([object[]]$Records)
    $map=@{}
    foreach($r in @($Records)) {
        if ($null -eq $r) {continue}
        $identity=Get-ScienceIdentity $r
        if ($map.ContainsKey([string]$r.name)) {throw "Duplicate package identity: $($r.name)"}
        $map[[string]$r.name]=$identity
    }
    return (@($map.Keys|Sort-Object|ForEach-Object {$map[$_]}) -join "`n")
}
function Assert-ScienceSameTransaction {
    param($Expected,$Actual,[string]$Phase)
    if (-not $Actual.success) {throw "$Phase did not report success"}
    foreach($action in @('LINK','UNLINK')) {
        if ((Get-ScienceRecordSignature @($Expected.actions.$action)) -cne (Get-ScienceRecordSignature @($Actual.actions.$action))) {throw "$Phase differs from the approved $action identities; no alternative transaction was accepted."}
    }
}
function Assert-SciencePlanPrefix {
    param($Plan,[string]$Prefix)
    foreach($reported in @($Plan.prefix,$Plan.actions.PREFIX)) {
        if ($null -ne $reported -and [IO.Path]::GetFullPath([string]$reported) -cne [IO.Path]::GetFullPath($Prefix)) {throw 'Native transaction reports another target prefix.'}
    }
}
function Get-SciencePrefixDigest {
    param([string]$Prefix)
    Assert-ScienceTransactionPath $Prefix
    $lines=@()
    $metadata=Join-Path $Prefix 'conda-meta'
    if(Test-Path -LiteralPath $metadata) {
        Assert-ScienceTransactionPath $metadata
        foreach($file in @(Get-ChildItem -LiteralPath $metadata -File|Where-Object {$_.Extension -ceq '.json' -or $_.Name -ceq 'history' -or $_.Name -ceq 'pinned'}|Sort-Object Name)) {
            Assert-ScienceRegularPath $file.FullName
            $lines+=($file.Name+'|'+(Get-ScienceFileSha256 $file.FullName))
        }
    }
    return Get-ScienceTextDigest ($lines -join "`n")
}
function Get-ScienceRemovalCandidates {
    param($Before,$Plan,[string]$Prefix)
    if(-not $Plan.success){throw 'Cannot review removals from an unsuccessful solve.'}
    Assert-SciencePlanPrefix $Plan $Prefix
    $null=Get-ScienceRecordSignature @($Plan.actions.LINK);$null=Get-ScienceRecordSignature @($Plan.actions.UNLINK)
    $after=@{};foreach($name in $Before.Keys){$after[$name]=$Before[$name]}
    foreach($record in @($Plan.actions.UNLINK)) {
        if($null -eq $record){continue}
        if(-not $Before.ContainsKey([string]$record.name) -or (Get-ScienceIdentity $Before[[string]$record.name]) -cne (Get-ScienceIdentity $record)){throw 'UNLINK does not match the installed package identity.'}
        $after.Remove([string]$record.name)
    }
    foreach($record in @($Plan.actions.LINK)){if($record){$after[[string]$record.name]=$record}}
    $removed=@($Before.Keys|Where-Object {-not $after.ContainsKey($_)}|Sort-Object)
    if(-not $removed.Count){return}
    if(-not $after.Count){throw 'Refusing removal of the complete Science package set.'}
    $configuration=Assert-ScienceConfiguration (Read-ScienceJson (Get-ScienceConfigurationPath))
    $protected=@{}
    foreach($name in @('python','python_abi','spyder','apache-arrow-proc','opencv','ffmpeg')){$protected[$name]=$true}
    foreach($spec in $configuration.ScientificPackages){$protected[(Get-ScienceSpecName $spec $configuration.Channels)]=$true}
    foreach($record in $Before.Values){if($record.requested_spec){$protected[(Get-ScienceSpecName $record.requested_spec)]=$true}}
    # History also protects manually requested packages no longer present in JSON.
    $history=Join-Path $Prefix 'conda-meta/history';Assert-ScienceRegularPath $history
    $historyRequestsFound=$false
    foreach($line in [IO.File]::ReadAllLines($history)) {
        if($line -match '^# (?:update|install|create) specs:\s*(.*)$') {
            $historyRequestsFound=$true
            $serialized=$Matches[1].Trim()
            if(-not $serialized.StartsWith('[')){throw 'Cannot establish requested-package ownership from history.'}
            $specs=ConvertFrom-Json -InputObject $serialized -ErrorAction Stop
            foreach($spec in $specs){$protected[(Get-ScienceSpecName $spec)]=$true}
        }
    }
    if(-not $historyRequestsFound){throw 'Cannot establish requested-package ownership from history.'}
    $pinned=Join-Path $Prefix 'conda-meta/pinned'
    if(Test-Path -LiteralPath $pinned){Assert-ScienceRegularPath $pinned;foreach($line in [IO.File]::ReadAllLines($pinned)){if($line.Trim() -and -not $line.Trim().StartsWith('#')){$protected[(Get-ScienceSpecName $line.Trim())]=$true}}}
    # Only the dependency closure of known requested/protected roots is owned.
    $dependencies=@{};$queue=New-Object 'Collections.Generic.Queue[string]'
    foreach($name in $protected.Keys){if($Before.ContainsKey($name)){$queue.Enqueue($name)}}
    while($queue.Count) {
        $name=$queue.Dequeue();if($dependencies.ContainsKey($name)){continue};$dependencies[$name]=$true
        foreach($spec in @($Before[$name].depends)){if($null -ne $spec){$dependency=Get-ScienceSpecName $spec;if($Before.ContainsKey($dependency)){$queue.Enqueue($dependency)}}}
    }
    foreach($name in $removed) {
        if($protected.ContainsKey($name)){throw "Refusing removal of explicitly requested/protected package: $name"}
        if($Before[$name].requested_spec -isnot [string] -or -not $dependencies.ContainsKey($name)){throw "Refusing removal of package with unproven dependency ownership: $name"}
        foreach($record in $after.Values){foreach($spec in @($record.depends)){if($null -ne $spec -and (Get-ScienceSpecName $spec) -ceq $name){throw "Refusing removal of dependency still required by $($record.name): $name"}}}
    }
    return $removed
}
function New-ScienceApprovedLock {
    param($Before,$Plan,[string]$Prefix,[string]$ConfigHash,[string]$ExecutableHash,[string[]]$RepairNames=@(),[string[]]$ApprovedRemovals=@())
    if (-not $Plan.success) {throw 'Cannot approve an unsuccessful solve.'}
    Assert-SciencePlanPrefix $Plan $Prefix
    $null=Get-ScienceRecordSignature @($Plan.actions.LINK);$null=Get-ScienceRecordSignature @($Plan.actions.UNLINK)
    $after=@{};foreach($name in $Before.Keys){$after[$name]=$Before[$name]}
    foreach($r in @($Plan.actions.UNLINK)) {
        if ($null -eq $r) {continue}
        if (-not $Before.ContainsKey([string]$r.name) -or (Get-ScienceIdentity $Before[[string]$r.name]) -cne (Get-ScienceIdentity $r)) {throw 'UNLINK does not match the installed package identity.'}
        $after.Remove([string]$r.name)
    }
    foreach($r in @($Plan.actions.LINK)) {if($null -ne $r){$after[[string]$r.name]=$r}}
    if((Get-ScienceRecordSignature @((Get-ScienceRecords $Prefix).Values)) -cne (Get-ScienceRecordSignature @($Before.Values))){throw 'Installed state changed during planning.'}
    $removed=@($Before.Keys|Where-Object {-not $after.ContainsKey($_)}|Sort-Object)
    if(($removed -join '|') -cne (@($ApprovedRemovals|Sort-Object) -join '|')){throw 'Package removal requires approval of exactly the disappearing dependency names.'}
    if($removed.Count) {
        if($RepairNames.Count){throw 'Package repair cannot remove package names.'}
        if((Get-ScienceFileSha256 (Get-ScienceConfigurationPath)) -cne $ConfigHash){throw 'Active configuration changed during removal review.'}
        $eligible=@(Get-ScienceRemovalCandidates $Before $Plan $Prefix)
        if(($eligible -join '|') -cne ($removed -join '|')){throw 'Approved removal eligibility changed.'}
    }
    $beforeRows=@($Before.Keys|Sort-Object|ForEach-Object {$Before[$_]})
    $afterRows=@($after.Keys|Sort-Object|ForEach-Object {$after[$_]})
    $null=Get-ScienceRecordSignature $beforeRows;$null=Get-ScienceRecordSignature $afterRows
    foreach($r in @($Plan.actions.LINK)) {if($null -ne $r){$null=Get-ScienceArtifactName $r}}
    return [pscustomobject][ordered]@{schema=1;prefix=[IO.Path]::GetFullPath($Prefix);prefix_files_sha256=(Get-SciencePrefixDigest $Prefix);before=$beforeRows;after=$afterRows;approved=$Plan;config_sha256=$ConfigHash;executable_sha256=$ExecutableHash;repair_names=@($RepairNames);approved_removals=@($ApprovedRemovals|Sort-Object)}
}
function Get-ScienceArtifactName {
    param($Record)
    $null=Get-ScienceIdentity $Record
    $uri=$null
    if (-not [Uri]::TryCreate([string]$Record.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {throw "Expected stable HTTPS package URL: $($Record.name)"}
    $filename=[Uri]::UnescapeDataString(($uri.AbsolutePath -split '/')[-1])
    $stem="$($Record.name)-$($Record.version)-$($Record.build)"
    if (@(($stem+'.conda'),($stem+'.tar.bz2')) -cnotcontains $filename -or ($uri.AbsolutePath -split '/')[-2] -cne [string]$Record.subdir) {throw "Artifact URL disagrees with package identity: $($Record.name)"}
    if ($Record.fn -and $Record.fn -cne $filename) {throw "Artifact filename disagrees with package metadata: $($Record.name)"}
    return $filename
}
function Get-ScienceCondaForgeRecords {
    param($Layout,[object[]]$Records)
    $source='https://conda.anaconda.org/conda-forge'
    $environment=@{MAMBA_ROOT_PREFIX=$Layout.Root;CONDA_PKGS_DIRS=$Layout.Pkgs;CONDA_SSL_VERIFY='true';MAMBA_SSL_VERIFY='true'}
    # Keep the complete Windows command line within the native length limit.
    for($start=0;$start -lt $Records.Count;$start+=75) {
        $end=[Math]::Min($start+74,$Records.Count-1)
        $specs=@($Records[$start..$end]|ForEach-Object {"$($_.name)==$($_.version)=$($_.build)"})
        $arguments=@('repoquery','search','--no-rc','-r',$Layout.Root,'--override-channels','-c',$source,'--repodata-ttl','0','--platform','win-64','--json')+$specs
        $batch=[int]($start/75)+1
        $result=Invoke-ScienceNative $Layout.Micromamba $arguments $environment
        if($result.ExitCode -ne 0){throw "Conda-forge metadata query failed (batch $batch, $($specs.Count) requests, exit $($result.ExitCode))."}
        try {$reply=ConvertFrom-ScienceTransactionJson $result.Stdout}
        catch {throw "Conda-forge metadata query returned invalid JSON (batch $batch, $($specs.Count) requests)."}
        if($reply.query.type -cne 'search' -or $reply.result.status -cne 'OK' -or $reply.result.pkgs -isnot [array]){
            throw "Conda-forge search did not return a valid package list (batch $batch, $($specs.Count) requests)."
        }
        $reply.result.pkgs
    }
}
function Get-ScienceSourceRepairs {
    param($Layout,[object[]]$Records,[string[]]$Channels)
    $legacy=@{}
    foreach($record in $Records) {
        $null=Get-ScienceIdentity $record
        $url=[string]$record.url
        $uri=$null
        if($url -and [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -ceq 'https'){
            $null=Get-ScienceArtifactName $record
            continue
        }
        if($url -and (-not $uri -or $url -cnotmatch '^file://' -or -not $uri.IsFile -or $uri.UserInfo -or $uri.Query -or $uri.Fragment)){
            throw "Unsafe installed package URL: $($record.name)"
        }
        $filename=[string]$record.fn
        if($uri) {
            $localName=[Uri]::UnescapeDataString(($uri.AbsolutePath -split '/')[-1])
            if($filename -and $filename -cne $localName){throw "Local artifact filename disagrees with package metadata: $($record.name)"}
            $filename=$localName
        }
        if($filename -and @("$($record.name)-$($record.version)-$($record.build).conda","$($record.name)-$($record.version)-$($record.build).tar.bz2") -cnotcontains $filename){
            throw "Local artifact filename disagrees with package identity: $($record.name)"
        }
        $legacy[[string]$record.name]=[pscustomobject]@{Record=$record;Filename=$filename}
    }
    $repairs=@{}
    if(-not $legacy.Count){return $repairs}
    $source='https://conda.anaconda.org/conda-forge'
    if(-not @($Channels|Where-Object {$_ -ceq 'conda-forge' -or $_.TrimEnd('/') -ceq $source}).Count){throw 'Conda-forge is required to verify legacy package metadata.'}
    Write-Host ("Verifying package sources with conda-forge for {0} installed records..." -f $legacy.Count)
    try {$rows=@(Get-ScienceCondaForgeRecords $Layout @($legacy.Values.Record))}
    catch {throw "Could not verify legacy package sources with conda-forge: $($_.Exception.Message)"}
    foreach($name in $legacy.Keys) {
        $item=$legacy[$name]
        $signature=Get-ScienceIdentity $item.Record
        $counts=[ordered]@{candidates=0;version=0;build=0;subdirectory=0;sha256=0;filename=0;url=0}
        $matches=@(foreach($candidate in $rows) {
            if($candidate.name -cne $name){continue}
            $counts.candidates++
            if($candidate.version -cne $item.Record.version){$counts.version++;continue}
            if($candidate.build -cne $item.Record.build){$counts.build++;continue}
            if($candidate.subdir -cne $item.Record.subdir){$counts.subdirectory++;continue}
            if($candidate.sha256 -cne $item.Record.sha256 -or (Get-ScienceIdentity $candidate) -cne $signature){$counts.sha256++;continue}

            # Require the literal trusted origin/channel/platform. Only the
            # final filename may be URL encoded (e.g. x264's epoch '!' as %21).
            $prefix="$source/$($candidate.subdir)/"
            $candidateUrl=[string]$candidate.url
            if(-not $candidateUrl.StartsWith($prefix,[StringComparison]::Ordinal)){$counts.url++;continue}
            $leaf=$candidateUrl.Substring($prefix.Length)
            if($leaf -cnotmatch '^(?:[A-Za-z0-9_.+!-]|%[0-9A-Fa-f]{2})+\z'){$counts.url++;continue}
            try {$fn=Get-ScienceArtifactName $candidate}
            catch {$counts.filename++;continue}
            if([Uri]::UnescapeDataString($leaf) -cne $fn){$counts.url++;continue}
            if($item.Filename -and $fn -cne $item.Filename){$counts.filename++;continue}
            [pscustomobject]@{url=$candidate.url;channel=$source;fn=$fn}
        })
        if($matches.Count -ne 1){
            $rejected=@(foreach($field in @('version','build','subdirectory','sha256','filename','url')){
                if($counts[$field]){"${field}=$($counts[$field])"}
            }) -join ', '
            if(-not $rejected){$rejected='none'}
            $record=$item.Record
            throw ("Conda-forge could not verify a unique source for {0} {1} {2} ({3}): candidates={4}, verified={5}, rejected at first check: {6}." -f
                $name,$record.version,$record.build,$record.subdir,$counts.candidates,$matches.Count,$rejected)
        }
        $repairs[$name]=$matches[0]
    }
    return $repairs
}
function Set-ScienceSourceProperties {
    param($Record,$Source)
    foreach($key in @('url','channel','fn')){
        $Record|Add-Member -NotePropertyName $key -NotePropertyValue $Source.$key -Force
    }
}
function Write-ScienceTransactionJson {
    param([string]$Path,$Value)
    Assert-ScienceTransactionPath $Path
    Set-ScienceAtomicBytes $Path ((New-Object Text.UTF8Encoding($false)).GetBytes(($Value|ConvertTo-Json -Depth 64)+"`n"))
}
function Show-ScienceTransaction {
    param($Plan,$Before)
    $linked=@{};foreach($r in @($Plan.actions.LINK)){if($null -ne $r){$linked[[string]$r.name]=$r}}
    $unlinked=@{};foreach($r in @($Plan.actions.UNLINK)){if($null -ne $r){$unlinked[[string]$r.name]=$r}}
    Write-Host 'Action | Package | Old version / build -> New version / build | Source'
    foreach($name in @(@($linked.Keys)+@($unlinked.Keys)|Sort-Object -Unique)) {
        $old=$Before[$name];$new=$linked[$name];$kind='Install'
        if($null -eq $new){$kind='Remove'} elseif($old) {
            $kind='Change'
            # Native build-only changes and reinstallations must remain visible.
            if($old.version -cne $new.version) {
                try {if((ConvertTo-ScienceVersion $new.version) -gt (ConvertTo-ScienceVersion $old.version)){$kind='Upgrade'}else{$kind='Downgrade'}} catch {$kind='Change'}
            }
        }
        $from='absent';if($old){$from="$($old.version) / $($old.build)"}
        $to='absent';$channel='';if($new){$to="$($new.version) / $($new.build)";$channel=[string]$new.channel}
        Write-Host "$kind | $name | $from -> $to | $channel"
    }
    $bytes=0L;foreach($r in @($Plan.actions.FETCH)){if($r){$bytes += [long]$r.size}}
    if($null -ne $Plan.actions.FETCH){Write-Host ('Estimated download: {0:N1} MiB' -f ($bytes/1MB))}else{Write-Host 'Estimated download: not supplied by solver'}
}
function Save-ScienceApprovedArchives {
    param($Lock,[string]$Directory,[string]$Cache)
    foreach($r in @($Lock.approved.actions.LINK)) {
        if($null -eq $r){continue}
        $filename=Get-ScienceArtifactName $r
        $folder=Join-Path (Join-Path $Directory 'channel') $r.subdir
        Assert-ScienceTransactionPath $folder;[void][IO.Directory]::CreateDirectory($folder)
        $dest=Join-Path $folder $filename
        if(Test-Path -LiteralPath $dest){Assert-ScienceRegularPath $dest;if((Get-ScienceFileSha256 $dest) -ceq $r.sha256){continue};throw 'Staged approved archive checksum mismatch.'}
        $uri=[Uri]$r.url
        $candidates=@((Join-Path $Cache $filename),(Join-Path $Cache ($uri.Scheme+'/'+$uri.Host+'/'+[Uri]::UnescapeDataString($uri.AbsolutePath.TrimStart('/')))))
        $temp=$dest+'.part-'+[Guid]::NewGuid().ToString('N')
        try {
            $copied=$false
            foreach($candidate in $candidates) {
                if(Test-Path -LiteralPath $candidate -PathType Leaf) {
                    try {Assert-ScienceRegularPath $candidate;if((Get-ScienceFileSha256 $candidate) -ceq $r.sha256){[IO.File]::Copy($candidate,$temp);$copied=$true;break}}catch{continue}
                }
            }
            if(-not $copied){[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $r.url -OutFile $temp -ErrorAction Stop|Out-Null}
            Assert-ScienceRegularPath $temp
            if((Get-ScienceFileSha256 $temp) -cne $r.sha256){throw "Approved archive SHA256 mismatch: $($r.name)"}
            [IO.File]::Move($temp,$dest)
        } finally {if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    }
}
function New-ScienceLockedInputs {
    param($Lock,[string]$Directory)
    $channel=Join-Path $Directory 'channel';$inputs=@{}
    foreach($subdir in @('win-64','noarch')) {
        $folder=Join-Path $channel $subdir;Assert-ScienceTransactionPath $folder;[void][IO.Directory]::CreateDirectory($folder)
        $rows=@{};$condaRows=@{}
        foreach($r in $Lock.after) {
            if($r.subdir -cne $subdir){continue}
            $filename=Get-ScienceArtifactName $r
            $row=[ordered]@{}
            foreach($key in @('name','version','build','build_number','depends','constrains','license','noarch','timestamp','size','md5','sha256','subdir','track_features')) {if($null -ne $r.$key){$row[$key]=$r.$key}}
            if(-not $row.Contains('build_number')){$row['build_number']=0}
            if(-not $row.Contains('depends')){$row['depends']=@()}
            if($filename.EndsWith('.conda')){$condaRows[$filename]=$row}else{$rows[$filename]=$row}
        }
        $path=Join-Path $folder 'repodata.json'
        Write-ScienceTransactionJson $path ([ordered]@{info=@{subdir=$subdir};packages=$rows;'packages.conda'=$condaRows;repodata_version=1})
        $inputs[$path]=Get-ScienceFileSha256 $path
    }
    $specs=@($Lock.after|ForEach-Object {"$($_.name)[version='==$($_.version)',build='$($_.build)',subdir='$($_.subdir)',sha256='$($_.sha256)']"})
    $environment=Join-Path $Directory 'locked-environment.yml'
    $channelUri=(New-Object Uri(([IO.Path]::GetFullPath($channel)+[IO.Path]::DirectorySeparatorChar),[UriKind]::Absolute)).AbsoluteUri.TrimEnd('/')
    Write-ScienceTransactionJson $environment ([ordered]@{channels=@($channelUri,'nodefaults');dependencies=$specs})
    $inputs[$environment]=Get-ScienceFileSha256 $environment
    $text="# platform: win-64`n@EXPLICIT`n"
    foreach($r in @($Lock.approved.actions.LINK)) {
        if($null -eq $r){continue}
        $path=Join-Path (Join-Path $channel $r.subdir) (Get-ScienceArtifactName $r)
        $text+=(New-Object Uri([IO.Path]::GetFullPath($path),[UriKind]::Absolute)).AbsoluteUri+'#'+$r.sha256+"`n"
    }
    $explicit=Join-Path $Directory 'explicit-local.txt';Set-ScienceAtomicBytes $explicit ([Text.Encoding]::UTF8.GetBytes($text));$inputs[$explicit]=Get-ScienceFileSha256 $explicit
    return [pscustomobject]@{Hashes=$inputs;Environment=$environment;Explicit=$explicit;Channel=$channelUri}
}
function ConvertFrom-ScienceTransactionJson {
    param([string]$Text)
    # Post-link scripts may write lines before JSON. PowerShell 5.1's JSON
    # converter can also ignore trailing text, so validate the complete document.
    $match=[regex]::Match($Text,'(?ms)^[\t ]*\{.*\}[\t \r\n]*\z')
    if(-not $match.Success){throw 'Native output does not end in one JSON object.'}
    if(-not ('ScienceStrictJson' -as [type])){Add-Type -Path (Join-Path (Get-ScienceSharedDirectory) 'StrictJson.cs') -ErrorAction Stop}
    [ScienceStrictJson]::Check($match.Value)
    $value=ConvertFrom-Json -InputObject $match.Value -ErrorAction Stop
    if($value -isnot [pscustomobject]){throw 'Native transaction output is not one JSON object.'}
    return $value
}
function Invoke-ScienceLockedTransaction {
    param($Layout,$Lock,[string]$Directory,[string]$ConfigPath,[string]$ExpectedLockDigest,[scriptblock]$BeforeCommit={},[hashtable]$CudaOverrides=@{})
    if($ExpectedLockDigest -cnotmatch '^[0-9a-f]{64}$' -or (Get-ScienceTextDigest ($Lock|ConvertTo-Json -Depth 64 -Compress)) -cne $ExpectedLockDigest){throw 'Approved identity changed before execution.'}
    if([IO.Path]::GetFullPath($Layout.Science) -cne [IO.Path]::GetFullPath($Lock.prefix)){throw 'Execution target differs from approved prefix.'}
    $finalNames=@($Lock.after|ForEach-Object {$_.name})
    $removed=@($Lock.before|Where-Object {$finalNames -cnotcontains $_.name}|ForEach-Object {$_.name}|Sort-Object)
    if(($removed -join '|') -cne (@($Lock.approved_removals|Where-Object {$null -ne $_}|Sort-Object) -join '|')){throw 'Locked removals differ from the separately approved dependency names.'}
    Assert-ScienceTransactionPath $Directory
    $lockPath=Join-Path $Directory 'approved-lock.json'
    Write-ScienceTransactionJson $lockPath $Lock
    $lockHash=Get-ScienceFileSha256 $lockPath
    $memoryHash=Get-ScienceTextDigest ($Lock|ConvertTo-Json -Depth 64 -Compress)
    Save-ScienceApprovedArchives $Lock $Directory $Layout.Pkgs
    $inputs=New-ScienceLockedInputs $Lock $Directory
    $privateCache=Join-Path $Directory 'cache';[void][IO.Directory]::CreateDirectory($privateCache)
    $environment=@{MAMBA_ROOT_PREFIX=$Layout.Root;CONDA_PKGS_DIRS=$privateCache;CONDA_SUBDIR='win-64';TEMP=$Layout.Tmp;TMP=$Layout.Tmp;TMPDIR=$Layout.Tmp;MAMBA_SAFETY_CHECKS='enabled';MAMBA_EXTRA_SAFETY_CHECKS='true'}
    foreach($name in $CudaOverrides.Keys){$environment[$name]=$CudaOverrides[$name]}
    $guard={
        if((Get-ScienceFileSha256 $lockPath) -cne $lockHash -or (Get-ScienceTextDigest ($Lock|ConvertTo-Json -Depth 64 -Compress)) -cne $memoryHash){throw 'Approved lock changed after approval.'}
        if((Get-ScienceFileSha256 $ConfigPath) -cne $Lock.config_sha256){throw 'Active configuration changed after approval.'}
        if((Get-ScienceFileSha256 $Layout.Micromamba) -cne $Lock.executable_sha256){throw 'Micromamba executable changed after approval.'}
        foreach($path in $inputs.Hashes.Keys){Assert-ScienceRegularPath $path;if((Get-ScienceFileSha256 $path) -cne $inputs.Hashes[$path]){throw 'Locked native input changed.'}}
        foreach($r in @($Lock.approved.actions.LINK)){if($r){$p=Join-Path (Join-Path (Join-Path $Directory 'channel') $r.subdir) (Get-ScienceArtifactName $r);Assert-ScienceRegularPath $p;if((Get-ScienceFileSha256 $p) -cne $r.sha256){throw 'Approved archive changed after staging.'}}}
        if((Get-ScienceRecordSignature @((Get-ScienceRecords $Layout.Science).Values)) -cne (Get-ScienceRecordSignature @($Lock.before))){throw 'Installed package identities changed after approval.'}
        Assert-ScienceTransactionPath $Layout.Science
        if((Get-SciencePrefixDigest $Layout.Science) -cne $Lock.prefix_files_sha256){throw 'Installed package metadata changed after approval.'}
    }
    $execute={param([string[]]$Arguments,[string]$Phase)
        $result=Invoke-ScienceNative $Layout.Micromamba $Arguments $environment
        if($Phase -ceq 'Locked commit'){$verification.native_exit_code=$result.ExitCode;$verification.stage='save-native-diagnostics'}
        $nativeDirectory=Join-Path $Directory ('native-'+($Phase.ToLowerInvariant() -replace '[^a-z0-9]+','-'))
        try {$nativeEvidence=Save-ScienceMambaFailure $Layout $Arguments $result $Phase -Directory $nativeDirectory -SummaryName result.json}
        catch {throw "$Phase returned exit $($result.ExitCode), but native diagnostics could not be saved; stopped without retry."}
        if($Phase -ceq 'Locked commit'){$verification.stage='native-exit'}
        if($result.ExitCode -ne 0){throw "$Phase failed (exit $($result.ExitCode)); diagnostics: $nativeEvidence . No automatic rollback or alternative plan was attempted."}
        if($Phase -ceq 'Locked commit'){$verification.stage='native-json'}
        try {$plan=ConvertFrom-ScienceTransactionJson $result.Stdout}
        catch {throw "$Phase returned invalid transaction JSON (native exit $($result.ExitCode)); diagnostics: $nativeEvidence"}
        if($Phase -ceq 'Locked commit'){$verification.native_json_parsed=$true;$verification.native_reported_success=$plan.success;$verification.stage='native-success'}
        if(-not $plan.success){throw "$Phase did not report success (native exit $($result.ExitCode)); diagnostics: $nativeEvidence"}
        return $plan
    }
    & $guard
    $downloadPrefix=Join-Path $Directory 'download-prefix'
    $preload=@('create','--no-rc','-r',$Layout.Root,'-p',$downloadPrefix,'--offline','--no-pyc','--json','--file',$inputs.Explicit,'--download-only','-y')
    $prepared=& $execute $preload 'Approved archive extraction'
    Assert-SciencePlanPrefix $prepared $downloadPrefix
    Assert-ScienceSameTransaction ([pscustomobject]@{actions=[pscustomobject]@{LINK=@($Lock.approved.actions.LINK);UNLINK=@()}}) $prepared 'Approved archive extraction'
    if(@($Lock.before).Count -eq 0){$command=@('create','--no-rc','-r',$Layout.Root,'-p',$Layout.Science,'--offline','--no-pyc','--json','--file',$inputs.Explicit)}
    elseif(@($Lock.repair_names).Count){
        foreach($r in @($Lock.approved.actions.LINK)) {
            $old=@($Lock.before|Where-Object {$_.name -ceq $r.name})
            if($old.Count -ne 1 -or (Get-ScienceIdentity $old[0]) -cne (Get-ScienceIdentity $r)){throw 'Repair must reinstall the same approved identities.'}
        }
        $command=@('install','--no-rc','-r',$Layout.Root,'-p',$Layout.Science,'--offline','--no-pyc','--json','--file',$inputs.Explicit)
    }elseif($removed.Count){
        # env update --prune retains some orphan dependencies in Micromamba 2.10.
        # update --all reproduces the approved removals against the locked universe.
        $command=@('update','--all','--no-rc','-r',$Layout.Root,'-p',$Layout.Science,'--offline','--json','--file',$inputs.Environment)
    }else{$command=@('env','update','--prune','--no-rc','-r',$Layout.Root,'-p',$Layout.Science,'--offline','--json','--file',$inputs.Environment)}
    & $guard
    $preflight=& $execute ($command+@('--dry-run')) 'Locked preflight'
    Assert-SciencePlanPrefix $preflight $Layout.Science
    Assert-ScienceSameTransaction $Lock.approved $preflight 'Locked preflight'
    Write-ScienceTransactionJson (Join-Path $Directory 'locked-preflight.json') $preflight
    & $guard
    & $BeforeCommit
    & $guard
    $verification=[ordered]@{stage='native-commit';native_exit_code=$null;native_json_parsed=$false;native_reported_success=$null;completed=$false;committed_plan_written=$false;installed_identities_verified=$false;exception_type=$null}
    try {
        $committed=& $execute ($command+@('-y')) 'Locked commit'
        $verification.stage='reported-prefix'
        Assert-SciencePlanPrefix $committed $Layout.Science
        $verification.stage='approved-link-unlink-identities'
        Assert-ScienceSameTransaction $Lock.approved $committed 'Locked commit'
        $verification.stage='write-committed-plan'
        Write-ScienceTransactionJson (Join-Path $Directory 'committed-plan.json') $committed
        $verification.committed_plan_written=$true
        $verification.stage='installed-identities'
        if((Get-ScienceRecordSignature @((Get-ScienceRecords $Layout.Science).Values)) -cne (Get-ScienceRecordSignature @($Lock.after))){throw 'Installed state differs from approved final identities.'}
        $verification.installed_identities_verified=$true
        $verification.stage='restore-source-metadata'
        # Preserve original dependency/channel metadata rather than ephemeral file:// sources.
        $byName=@{};foreach($r in $Lock.after){$byName[[string]$r.name]=$r}
        foreach($file in Get-ChildItem -LiteralPath (Join-Path $Layout.Science 'conda-meta') -Filter '*.json' -File){
            $actual=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json;$record=$byName[[string]$actual.name]
            foreach($key in @('url','channel','fn','depends','constrains','subdir','sha256')){if($null -ne $record.$key){$actual|Add-Member -NotePropertyName $key -NotePropertyValue $record.$key -Force}}
            Write-ScienceTransactionJson $file.FullName $actual
        }
        $verification.stage='final-input-integrity'
        if((Get-ScienceFileSha256 $lockPath) -cne $lockHash){throw 'Approved lock changed during commit.'}
        foreach($path in $inputs.Hashes.Keys){if((Get-ScienceFileSha256 $path) -cne $inputs.Hashes[$path]){throw 'Locked input changed during commit.'}}
        $verification.stage='complete';$verification.completed=$true
    } catch {$verification.exception_type=$_.Exception.GetType().FullName;throw}
    finally {
        try {Write-ScienceTransactionJson (Join-Path $Directory 'commit-verification.json') $verification}
        catch {if($verification.completed){throw 'Commit verification evidence could not be written.'}else{Write-Warning 'Commit failure evidence could not be written; inspect native transaction diagnostics.'}}
    }
    return $committed
}
