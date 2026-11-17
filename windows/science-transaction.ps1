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
        foreach($file in @(Get-ChildItem -LiteralPath $metadata -File|Where-Object {$_.Extension -ceq '.json' -or $_.Name -ceq 'history'}|Sort-Object Name)) {
            Assert-ScienceRegularPath $file.FullName
            $lines+=($file.Name+'|'+(Get-ScienceFileSha256 $file.FullName))
        }
    }
    return Get-ScienceTextDigest ($lines -join "`n")
}
function New-ScienceApprovedLock {
    param($Before,$Plan,[string]$Prefix,[string]$ConfigHash,[string]$ExecutableHash,[string[]]$RepairNames=@())
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
    # Install/update never owns arbitrary packages or removes names absent from JSON.
    foreach($name in $Before.Keys){if(-not $after.ContainsKey($name)){throw "Refusing package removal during Install/update: $name"}}
    $beforeRows=@($Before.Keys|Sort-Object|ForEach-Object {$Before[$_]})
    $afterRows=@($after.Keys|Sort-Object|ForEach-Object {$after[$_]})
    $null=Get-ScienceRecordSignature $beforeRows;$null=Get-ScienceRecordSignature $afterRows
    foreach($r in @($Plan.actions.LINK)) {if($null -ne $r){$null=Get-ScienceArtifactName $r}}
    return [pscustomobject][ordered]@{schema=1;prefix=[IO.Path]::GetFullPath($Prefix);prefix_files_sha256=(Get-SciencePrefixDigest $Prefix);before=$beforeRows;after=$afterRows;approved=$Plan;config_sha256=$ConfigHash;executable_sha256=$ExecutableHash;repair_names=@($RepairNames)}
}
function Get-ScienceArtifactName {
    param($Record)
    $null=Get-ScienceIdentity $Record
    $uri=$null
    if (-not [Uri]::TryCreate([string]$Record.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {throw "Expected stable HTTPS package URL: $($Record.name)"}
    $filename=[Uri]::UnescapeDataString(($uri.AbsolutePath -split '/')[-1])
    $stem="$($Record.name)-$($Record.version)-$($Record.build)"
    if (@(($stem+'.conda'),($stem+'.tar.bz2')) -cnotcontains $filename -or ($uri.AbsolutePath -split '/')[-2] -cne [string]$Record.subdir) {throw "Artifact URL disagrees with package identity: $($Record.name)"}
    return $filename
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
function Invoke-ScienceLockedTransaction {
    param($Layout,$Lock,[string]$Directory,[string]$ConfigPath,[string]$ExpectedLockDigest,[scriptblock]$BeforeCommit={})
    if($ExpectedLockDigest -cnotmatch '^[0-9a-f]{64}$' -or (Get-ScienceTextDigest ($Lock|ConvertTo-Json -Depth 64 -Compress)) -cne $ExpectedLockDigest){throw 'Approved identity changed before execution.'}
    if([IO.Path]::GetFullPath($Layout.Science) -cne [IO.Path]::GetFullPath($Lock.prefix)){throw 'Execution target differs from approved prefix.'}
    Assert-ScienceTransactionPath $Directory
    $lockPath=Join-Path $Directory 'approved-lock.json'
    Write-ScienceTransactionJson $lockPath $Lock
    $lockHash=Get-ScienceFileSha256 $lockPath
    $memoryHash=Get-ScienceTextDigest ($Lock|ConvertTo-Json -Depth 64 -Compress)
    Save-ScienceApprovedArchives $Lock $Directory $Layout.Pkgs
    $inputs=New-ScienceLockedInputs $Lock $Directory
    $privateCache=Join-Path $Directory 'cache';[void][IO.Directory]::CreateDirectory($privateCache)
    $environment=@{MAMBA_ROOT_PREFIX=$Layout.Root;CONDA_PKGS_DIRS=$privateCache;CONDA_SUBDIR='win-64';TEMP=$Layout.Tmp;TMP=$Layout.Tmp;TMPDIR=$Layout.Tmp;MAMBA_SAFETY_CHECKS='enabled';MAMBA_EXTRA_SAFETY_CHECKS='true'}
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
        if($result.ExitCode -ne 0){throw "$Phase failed (exit $($result.ExitCode)); inspect transaction evidence. No automatic rollback or alternative plan was attempted. $($result.Stderr) $($result.Stdout)"}
        $plan=$result.Stdout|ConvertFrom-Json -ErrorAction Stop
        if(-not $plan.success){throw "$Phase did not report success."}
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
    }else{$command=@('env','update','--prune','--no-rc','-r',$Layout.Root,'-p',$Layout.Science,'--offline','--json','--file',$inputs.Environment)}
    & $guard
    $preflight=& $execute ($command+@('--dry-run')) 'Locked preflight'
    Assert-SciencePlanPrefix $preflight $Layout.Science
    Assert-ScienceSameTransaction $Lock.approved $preflight 'Locked preflight'
    Write-ScienceTransactionJson (Join-Path $Directory 'locked-preflight.json') $preflight
    & $guard
    & $BeforeCommit
    & $guard
    $committed=& $execute ($command+@('-y')) 'Locked commit'
    Assert-SciencePlanPrefix $committed $Layout.Science
    Assert-ScienceSameTransaction $Lock.approved $committed 'Locked commit'
    Write-ScienceTransactionJson (Join-Path $Directory 'committed-plan.json') $committed
    if((Get-ScienceRecordSignature @((Get-ScienceRecords $Layout.Science).Values)) -cne (Get-ScienceRecordSignature @($Lock.after))){throw 'Installed state differs from approved final identities.'}
    # Preserve original dependency/channel metadata rather than ephemeral file:// sources.
    $byName=@{};foreach($r in $Lock.after){$byName[[string]$r.name]=$r}
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $Layout.Science 'conda-meta') -Filter '*.json' -File){
        $actual=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json;$record=$byName[[string]$actual.name]
        foreach($key in @('url','channel','fn','depends','constrains','subdir','sha256')){if($null -ne $record.$key){$actual|Add-Member -NotePropertyName $key -NotePropertyValue $record.$key -Force}}
        Write-ScienceTransactionJson $file.FullName $actual
    }
    if((Get-ScienceFileSha256 $lockPath) -cne $lockHash){throw 'Approved lock changed during commit.'}
    foreach($path in $inputs.Hashes.Keys){if((Get-ScienceFileSha256 $path) -cne $inputs.Hashes[$path]){throw 'Locked input changed during commit.'}}
    return $committed
}
