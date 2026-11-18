# Loaded only after the source bundle has been verified.
function Initialize-ScienceRootNative {
    if(-not ('ScienceRootNative' -as [type])){
        Add-Type -Path (Join-Path $PSScriptRoot 'science-root-native.cs') -ErrorAction Stop
    }
}

function Assert-ScienceRootAcl {
    param([string]$Path,[switch]$Anchor,[switch]$CreatedSafeRoot)
    $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
    $sid=(Get-ScienceSidInfo).Sid
    $writers=@($sid,'S-1-5-18','S-1-5-32-544')
    if($Anchor){$writers+=,'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'}
    if($writers -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -or
       (-not $Anchor -and -not $CreatedSafeRoot -and $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid)){
        throw "Ownership cannot be verified for $Path"
    }
    # Writable data, append, child-delete, delete, change permissions or owner.
    # AddFile/AddDirectory on an ancestor cannot redirect an already anchored
    # child; delete-child permissions on the immediate parent can.
    $mask=if($Anchor){0x100D0040}else{0x500D0156}
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -eq 'Allow' -and
           -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
           ($rule.FileSystemRights -band $mask) -and $writers -notcontains $rule.IdentityReference.Value){
            throw "Unexpected write/delete ACL on $Path"
        }
    }
    if($CreatedSafeRoot -and (-not $acl.AreAccessRulesProtected -or -not @(
        $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {
            $_.IdentityReference.Value -eq $sid -and $_.AccessControlType -eq 'Allow' -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -eq [Security.AccessControl.FileSystemRights]::Modify
        }).Count)){throw 'Safe-mode root does not have its dedicated installer ACL.'}
}

function Get-ScienceRootSnapshot {
    param([string]$Root,[switch]$CreatedSafeRoot)
    $result=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $pending=New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    Assert-ScienceRootAcl ([IO.Path]::GetDirectoryName($Root)) -Anchor
    while($pending.Count){
        $item=$pending.Pop()
        if($result.Count -ge 300000){throw 'Removal inventory exceeded 300,000 entries.'}
        $anchor=[ScienceRootNative+Anchor]::new($item,$result)
        try {
            $sig=[ScienceRootNative]::Inspect($item,$true)
            if($CreatedSafeRoot -and $item -ieq $Root){Assert-ScienceRootAcl $item -CreatedSafeRoot}
            else{Assert-ScienceRootAcl $item}
            $result.Add($item,$sig)
            if([Convert]::ToUInt32(($sig -split ':')[2],16) -band 16){
                foreach($child in [IO.Directory]::EnumerateFileSystemEntries($item)){$pending.Push($child)}
            }
        } finally {$anchor.Dispose()}
    }
    return ,$result
}

function Get-ScienceCondaScope {
    param([string]$Prefix)
    $paths=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $metadata=Join-Path $Prefix 'conda-meta'
    $history=Join-Path $metadata 'history'
    if(-not [IO.File]::Exists($history)){throw "No Conda history in $Prefix"}
    [void]$paths.Add($history);[void]$paths.Add((Join-Path $metadata 'pinned'))
    $count=0
    foreach($file in [IO.Directory]::EnumerateFiles($metadata,'*.json')){
        $count++
        if($count -gt 5000 -or ([IO.FileInfo]::new($file)).Length -gt 20MB){throw "Conda metadata limit exceeded: $file"}
        $record=Read-ScienceJson $file
        if([IO.Path]::GetFileName($file) -cne "$($record.name)-$($record.version)-$($record.build).json" -or $record.files -isnot [array]){
            throw "Unidentified Conda metadata: $file"
        }
        [void]$paths.Add($file)
        foreach($entry in $record.files){
            if($entry -isnot [string] -or -not $entry -or $entry -match '(^[\\/]|:|(^|[\\/])\.\.?([\\/]|$)|[\x00-\x1f])'){
                throw "Unsafe package entry in $file"
            }
            $full=[IO.Path]::GetFullPath((Join-Path $Prefix $entry))
            if(-not (Test-PathWithin $full $Prefix)){throw "Package entry leaves $Prefix"}
            [void]$paths.Add($full)
        }
    }
    if(-not $count -and ([IO.FileInfo]::new($history)).Length){throw "History without package metadata: $Prefix"}
    return ,$paths
}

function Add-ScienceScopedPath {
    param($Allowed,[string]$Path,[string]$Root)
    while($Path -ine $Root -and (Test-PathWithin $Path $Root)){
        [void]$Allowed.Add($Path)
        $Path=[IO.Path]::GetDirectoryName($Path)
    }
}

function Assert-ScienceRootProcesses {
    param([string]$Root,[string]$Executable)
    if($env:CONDA_PREFIX -and (Test-PathWithin $env:CONDA_PREFIX $Root)){throw 'Deactivate the selected environment in the calling console first.'}
    foreach($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)){
        if($process.ProcessId -eq $PID){continue}
        if(($process.ExecutablePath -and ((Test-PathWithin $process.ExecutablePath $Root) -or $process.ExecutablePath -ieq $Executable)) -or
           ($process.CommandLine -and $process.CommandLine.IndexOf($Root,[StringComparison]::OrdinalIgnoreCase) -ge 0)){
            throw "A process still references the selected root (PID $($process.ProcessId))."
        }
    }
}

function Test-ScienceCacheEntry {
    param([string]$Cache,[string]$Path,$Memo)
    $relative=$Path.Substring($Cache.TrimEnd('\').Length).TrimStart('\')
    if($relative -match '^(urls(?:\.txt)?|\.mamba_lock|cache(?:\\[a-fA-F0-9]{8,64}(?:\.state)?\.(?:json|solv|lock))?)$'){return $true}
    if($relative -match '^[\w.+-]+-[\w.+-]+-[\w.+-]+\.(?:conda|tar\.bz2)$'){return $true}
    $dir=($relative -split '\\')[0]
    $package=Join-Path $Cache $dir
    if(-not $Memo.ContainsKey($package)){
        $index=Join-Path $package 'info\index.json'
        if(-not [IO.File]::Exists($index)){return $false}
        $item=Read-ScienceJson $index
        if($dir -cne "$($item.name)-$($item.version)-$($item.build)"){return $false}
        $manifest=Join-Path $package 'info\paths.json'
        $files=Join-Path $package 'info\files'
        if([IO.File]::Exists($manifest)){
            $metadata=Read-ScienceJson $manifest
            if($metadata.paths -isnot [array]){return $false}
            $names=@($metadata.paths | ForEach-Object {$_._path})
        }else{
            Assert-ScienceRegularPath $files
            $names=[IO.File]::ReadAllLines($files)
        }
        $known=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($name in $names){
            if($name -isnot [string] -or $name -match '(^[\\/]|:|(^|[\\/])\.\.?([\\/]|$)|[\x00-\x1f])'){throw "Unsafe cache manifest: $package"}
            Add-ScienceScopedPath $known ([IO.Path]::GetFullPath((Join-Path $package $name))) $package
        }
        foreach($name in 'index.json','paths.json','repodata_record.json','files','about.json','hash_input.json','link.json','git','run_exports.json','has_prefix','no_link','no_softlink','test','recipe','licenses'){
            [void]$known.Add((Join-Path $package "info\$name"))
        }
        [void]$known.Add((Join-Path $package 'info'))
        $Memo[$package]=$known
    }
    if($Path -ieq $package -or $Memo[$package].Contains($Path)){return $true}
    return $Path -match '\\info\\(?:test|recipe|licenses)\\'
}

function Test-ScienceTransactionEvidencePath {
    param($Layout,[string]$Path,$Snapshot,$Memo)
    if(-not (Test-PathWithin $Path $Layout.Tmp) -or $Path -ieq $Layout.Tmp){return $false}
    $relative=$Path.Substring($Layout.Tmp.Length+1)
    if($relative -match '^(repoquery-[a-f0-9]{32}\.txt|librsvg-hook-[a-f0-9]{32}\.original)$'){return $true}
    if($relative -match '^science-solver-failure-[a-f0-9]{32}(?:\\(?:stdin|stdout|stderr)\.txt|\\[^\\]+\.json)?$'){return $true}
    $parts=$relative -split '\\',2
    if($parts[0] -cnotmatch '^science-transaction-[a-f0-9]{32}$'){return $false}
    $tx=Join-Path $Layout.Tmp $parts[0]
    if(-not $Memo.ContainsKey($tx)){
        $lock=Join-Path $tx 'approved-lock.json'
        if(-not $Snapshot.ContainsKey($lock)){return $false}
        $approved=Read-ScienceJson $lock
        if($approved.prefix -ine $Layout.Science){return $false}
        $Memo[$tx]=$approved
    }
    if($parts.Count -eq 1){return $true}
    $item=$parts[1]
    if($item -match '^(approved-lock\.json|explicit-local\.txt|locked-environment\.yml|locked-preflight\.json|committed-plan\.json|commit-verification\.json|native-[a-z0-9-]+(?:\\(?:stdout\.txt|stderr\.txt|result\.json))?|download-prefix(?:\\conda-meta(?:\\history)?)?)$'){return $true}
    if($item -match '^cache(?:\\|$)'){
        $cache=Join-Path $tx 'cache'
        if(-not $Memo.ContainsKey('stores:'+ $cache)){$Memo['stores:'+ $cache]=Get-ScienceCacheStores $cache $Snapshot}
        return ($item -eq 'cache' -or (Test-ScienceCachePath $cache $Path $Memo $Memo['stores:'+ $cache]))
    }
    if($item -match '^channel(?:\\(?:win-64|noarch))?$'){return $true}
    if($item -match '^channel\\(?:win-64|noarch)\\(?:repodata\.json|repodata\.json\.zst)$'){return $true}
    foreach($record in @($Memo[$tx].approved.actions.LINK)){
        if($record -and $item -ceq ('channel\'+$record.subdir+'\'+(Get-ScienceArtifactName $record))){return $true}
    }
    return $false
}

function Get-ScienceCleanupSetting {
    param([string]$Name,[string]$Scope)
    return [Environment]::GetEnvironmentVariable($Name,$Scope)
}

function Get-ScienceCleanupConfigDirectories {
    @($HOME,(Join-Path $HOME '.conda'),(Join-Path $HOME '.config\conda'),(Join-Path $HOME '.config\mamba'),
        $env:ProgramData,$env:LOCALAPPDATA)
    if($env:ProgramData){Join-Path $env:ProgramData 'conda';Join-Path $env:ProgramData 'mamba'}
    if($env:XDG_CONFIG_HOME){Join-Path $env:XDG_CONFIG_HOME 'conda';Join-Path $env:XDG_CONFIG_HOME 'mamba'}
}

function Assert-ScienceRemovalResources {
    param($Inventory,[string]$Root,[string]$Executable)
    foreach($entry in @($Inventory.External)){
        if((Test-PathWithin $entry $Root) -or (Test-PathWithin $Root $entry)){
            throw "An external registration overlaps the selected root: $entry"
        }
    }
    foreach($scope in 'Process','User','Machine'){
        $configuredRoot=Get-ScienceCleanupSetting 'MAMBA_ROOT_PREFIX' $scope
        $configuredExe=Get-ScienceCleanupSetting 'MAMBA_EXE' $scope
        if($configuredExe -and $configuredExe -ieq $Executable -and ($scope -eq 'Machine' -or $configuredRoot -ine $Root)){
            throw "Shared executable reference ($scope MAMBA_EXE)."
        }
        if($scope -eq 'Machine' -and $configuredRoot -ieq $Root){throw 'Machine-wide root selection cannot be changed by this operation.'}
    }
}

function Test-ScienceChannelOnlyConfig {
    param([string]$Path)
    Assert-ScienceRegularPath $Path
    if(([IO.FileInfo]::new($Path)).Length -gt 32KB){return $false}
    $lines=@([IO.File]::ReadAllLines($Path)|Where-Object {$_ -notmatch '^\s*(?:#.*)?$'})
    return ($lines.Count -gt 0 -and $lines[0] -ceq 'channels:' -and
        @($lines|Select-Object -Skip 1|Where-Object {$_ -cnotmatch '^\s+-\s+[A-Za-z0-9_.-]+\s*$'}).Count -eq 0)
}

function Get-ScienceTotalRemovalPlan {
    param($Row,$Inventory,[string]$ExpectedSha256)
    Initialize-ScienceRootNative
    $layout=$Row.Layout
    $root=$layout.Root
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
    if($drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS' -or
       $root -cne ([IO.Path]::GetFullPath($root)) -or $root -ieq $drive.RootDirectory.FullName -or
       $root -ieq $HOME -or (Test-PathWithin $HOME $root) -or (Test-PathWithin $PSScriptRoot $root)){
        throw 'Select a dedicated local NTFS directory separate from the user profile and running installer.'
    }
    if(@($Row.Unknown).Count -or @($Inventory.Problems).Count){throw 'Unknown or inaccessible inventory entries prevent proving the deletion scope.'}
    if(-not $Row.VerifiedExecutable){throw 'The selected Micromamba executable does not match a trusted release hash.'}
    Assert-ScienceRemovalResources $Inventory $root $layout.Micromamba
    foreach($candidate in @($Inventory.Roots)){
        if(-not $candidate.Layout.Pkgs){continue}
        $pkgs=[IO.DirectoryInfo]::new($candidate.Layout.Pkgs)
        if($pkgs.Exists -and ($pkgs.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            throw "A detected package cache is redirected and may be shared: $($pkgs.FullName)"
        }
    }
    foreach($other in @($Inventory.Roots|Where-Object {$_.Root -ine $root})){
        if((Test-PathWithin $other.Root $root) -or (Test-PathWithin $root $other.Root) -or
           $other.Layout.Micromamba -ieq $layout.Micromamba -or (Test-PathWithin $other.Layout.Micromamba $root)){
            throw "Another root overlaps this root or shares its executable: $($other.Root)"
        }
    }
    $state=$null
    $managed=$false
    if($layout.State -and [IO.File]::Exists($layout.State)){
        Assert-ScienceRegularPath $layout.State
        $state=Read-ScienceJson $layout.State
        $managed=$state.schema_version -eq 2 -and $state.user_sid -ceq (Get-ScienceSidInfo).Sid -and
                 $state.root -ieq $root -and $state.micromamba -ieq $layout.Micromamba -and
                 $state.root_existed_before -is [bool] -and -not $state.root_existed_before -and
                 $state.micromamba_existed_before -is [bool] -and -not $state.micromamba_existed_before
        if(-not $managed){throw 'This installer state does not prove that the installer created the root and executable.'}
        if($Row.Environments -contains 'science'){Assert-ScienceOwnedPrefix $layout $state}
    } elseif(-not (Test-PathWithin $layout.Micromamba $root) -or -not $Row.Environments.Count){
        throw 'User-managed root needs a trusted executable within the root and independently recognized environment metadata.'
    }
    $external=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $registry=$Inventory.Registry
    $removeRegistrations=@()
    foreach($entry in @($registry.Paths)){
        if(Test-PathWithin $entry $root){
            $known=@($Row.Environments|ForEach-Object {if($_ -eq 'base'){$root}else{Join-Path $layout.Envs $_}})
            if($entry -ine $root -and $known -notcontains $entry){throw "Unknown registered prefix is inside the root: $entry"}
            $removeRegistrations+=,$entry
        }
    }
    if($removeRegistrations.Count){
        Assert-ScienceRootAcl ([IO.Path]::GetDirectoryName($registry.Path)) -Anchor
        Assert-ScienceRootAcl $registry.Path
        [void][ScienceRootNative]::Inspect($registry.Path,$true)
    }
    $integration=@{}
    foreach($scope in 'Process','User','Machine'){
        foreach($name in 'CONDA_PKGS_DIRS','MAMBA_PKGS_DIRS','CONDA_ENVS_PATH','CONDA_ENVS_DIRS','MAMBA_ENVS_DIRS','CONDARC','MAMBARC'){
            $value=Get-ScienceCleanupSetting $name $scope
            if(-not $value){continue}
            $associated=Get-ScienceCleanupSetting 'MAMBA_ROOT_PREFIX' $scope
            if($name -eq 'CONDA_PKGS_DIRS' -and $scope -ne 'Machine' -and $associated){
                $association=@($Inventory.Roots|Where-Object {$_.Root -ieq $associated -and $_.Layout.Pkgs -ieq $value})
                if($association.Count -eq 1){continue}
            }
            throw "Custom or shared cache/environment configuration cannot be excluded ($scope $name)."
        }
    }
    foreach($cfg in @(Get-ScienceCleanupConfigDirectories)+@($Inventory.Roots.Root)){
        if(-not $cfg){continue}
        foreach($name in '.condarc','.mambarc','condarc','mambarc','condarc.d','mambarc.d'){
            $path=Join-Path $cfg $name
            if(-not (Test-Path -LiteralPath $path)){continue}
            $supportedConfig=@($Inventory.Roots | Where-Object {$_.Mode -in 'Home','Safe' -and $_.Layout.Config -ieq $path})
            if(($supportedConfig.Count -eq 1 -or ($managed -and $path -ieq $layout.Config)) -and [IO.File]::Exists($path)){
                Assert-ScienceRegularPath $path
                if([IO.File]::ReadAllText($path).Trim() -ceq 'use_sharded_repodata: false'){continue}
            }
            if([IO.File]::Exists($path) -and (Test-ScienceChannelOnlyConfig $path)){
                if($cfg -ieq $root){throw "The selected root contains a user configuration: $path"}
                continue
            }
            throw "A custom configuration may share resources: $path"
        }
    }
    foreach($profilePath in @($PROFILE.CurrentUserAllHosts,$PROFILE.CurrentUserCurrentHost)|Select-Object -Unique){
        if($profilePath -and [IO.File]::Exists($profilePath)){
            Assert-ScienceRegularPath $profilePath
            if([IO.File]::ReadAllText($profilePath).IndexOf($root,[StringComparison]::OrdinalIgnoreCase) -ge 0){
                throw "Custom shell integration references this root; resolve it before removal: $profilePath"
            }
        }
    }
    Assert-ScienceRootProcesses $root $layout.Micromamba
    $snapshot=Get-ScienceRootSnapshot $root -CreatedSafeRoot:($managed -and $layout.Mode -eq 'Safe' -and $layout.Sid -ceq (Get-ScienceSidInfo).Sid)
    if($managed -and $state.root_file_identity -and $state.root_file_identity -cne $snapshot[$root].Substring(0,26)){
        throw 'Root directory identity disagrees with the installer state.'
    }
    Assert-ScienceRegularPath $layout.Micromamba
    if((Get-FileHash -LiteralPath $layout.Micromamba -Algorithm SHA256 -ErrorAction Stop).Hash -ine $ExpectedSha256){throw 'Micromamba changed during planning.'}
    $allowed=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($path in @($layout.Micromamba,$layout.Envs,$layout.Pkgs)){Add-ScienceScopedPath $allowed $path $root}
    $payload=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($name in $Row.Environments){
        if($name -ne 'base' -and ($name -ne [IO.Path]::GetFileName($name) -or $name -in '.','..')){throw 'Invalid environment inventory name.'}
        $prefix=if($name -eq 'base'){$root}else{Join-Path $layout.Envs $name}
        foreach($path in (Get-ScienceCondaScope $prefix)){
            [void]$payload.Add($path)
            Add-ScienceScopedPath $allowed $path $root
        }
    }
    if($managed){
        foreach($name in '.science-update.lock','.scientific-python-install-state.json','.mambarc','start-spyder.ps1','science-runtime.json','science-packages.json','science-other-environments.json','SHA256SUMS.txt','envs/science/.science-environment-owner','tmp'){
            Add-ScienceScopedPath $allowed (Join-Path $root $name) $root
        }
        $manifest=Join-Path $root 'SHA256SUMS.txt'
        if([IO.File]::Exists($manifest) -and ([IO.FileInfo]::new($manifest)).Length -lt 256KB){
            foreach($line in [IO.File]::ReadAllLines($manifest)){
                if($line -cnotmatch '^([0-9a-f]{64})  ([A-Za-z0-9_. /-]+)$' -or $Matches[2] -match '(^/|(^|/)\.\.(/|$))'){throw 'Invalid installed support manifest.'}
                $hash=$Matches[1];$path=Join-Path $root $Matches[2]
                if([IO.File]::Exists($path) -and $snapshot.ContainsKey($path.Replace('/','\')) -and
                   (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ieq $hash){Add-ScienceScopedPath $allowed $path.Replace('/','\') $root}
            }
        }
        $launch=Get-ScientificPythonSpyderLauncherPaths $layout
        if([IO.File]::Exists($launch.Script)){
            Assert-ScienceRegularPath $launch.Script
            $installedTemplate=Join-Path $root 'spyder-launcher.ps1'
            $template=if([IO.File]::Exists($installedTemplate) -and $allowed.Contains($installedTemplate)){$installedTemplate}
                else{Join-Path $PSScriptRoot 'spyder-launcher.ps1'}
            if((Get-ScienceFileSha256 $launch.Script) -cne (Get-ScienceFileSha256 $template)){
                throw 'Unidentified Spyder launcher script.'
            }
        }
        if([IO.File]::Exists($launch.Command)){
            Assert-ScienceRegularPath $launch.Command
            if([IO.File]::ReadAllText($launch.Command).IndexOf($launch.Script,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw 'Unidentified Spyder command launcher.'}
            if(Test-PathWithin $launch.Command $root){Add-ScienceScopedPath $allowed $launch.Command $root}
            else{Assert-ScienceRootAcl $launch.Command; $external.Add($launch.Command,[ScienceRootNative]::Inspect($launch.Command,$true))}
        }
        if(Test-ScientificPythonSpyderShortcut $launch.Shortcut $launch.Script){
            Assert-ScienceRegularPath $launch.Shortcut
            Assert-ScienceRootAcl $launch.Shortcut
            $external.Add($launch.Shortcut,[ScienceRootNative]::Inspect($launch.Shortcut,$true))
        }
        if($state.bin_path_existed_before -is [bool] -and -not $state.bin_path_existed_before){
            $pathValue=Get-ScienceCleanupSetting 'Path' 'User'
            if($pathValue){
                $pathParts=$pathValue -split ';'
                $nextPath=($pathParts | Where-Object {$_ -ine $layout.Bin}) -join ';'
                if($nextPath -cne $pathValue){$integration['User/Path']=@($pathValue,$nextPath)}
            }
        }
    }
    foreach($scope in 'User','Process'){
        if((Get-ScienceCleanupSetting 'MAMBA_ROOT_PREFIX' $scope) -ine $root){continue}
        foreach($pair in @(@('MAMBA_ROOT_PREFIX',$root,'previous_mamba_root_prefix'),@('CONDA_PKGS_DIRS',$layout.Pkgs,'previous_conda_pkgs_dirs'),@('MAMBA_EXE',$layout.Micromamba,'previous_mamba_exe'))){
            if((Get-ScienceCleanupSetting $pair[0] $scope) -ieq $pair[1]){
                $previous=if($managed -and $scope -eq 'User'){[string]$state.($pair[2])}else{''}
                if($previous -and ((Test-PathWithin $previous $root) -or $previous -ieq $layout.Micromamba)){$previous=''}
                $integration["$scope/$($pair[0])"]=@($pair[1],$previous)
            }
        }
    }
    if(-not (Test-PathWithin $layout.Micromamba $root)){
        Assert-ScienceRootAcl $layout.Micromamba
        $external.Add($layout.Micromamba,[ScienceRootNative]::Inspect($layout.Micromamba,$true))
    }
    $memo=@{}
    $cacheStores=Get-ScienceCacheStores $layout.Pkgs $snapshot
    foreach($path in $snapshot.Keys){
        if($path -ieq $root -or $allowed.Contains($path)){continue}
        if((Split-Path -Leaf $path) -match '^(.+)\.cpython-\d+(?:\.opt-\d+)?\.pyc$' -and (Split-Path -Leaf (Split-Path -Parent $path)) -ceq '__pycache__' -and
           $payload.Contains((Join-Path (Split-Path -Parent (Split-Path -Parent $path)) ($Matches[1]+'.py')))){continue}
        if(([Convert]::ToUInt32(($snapshot[$path] -split ':')[2],16) -band 16) -and (Split-Path -Leaf $path) -ceq '__pycache__' -and
           $allowed.Contains((Split-Path -Parent $path)) -and @([IO.Directory]::EnumerateDirectories($path)).Count -eq 0){continue}
        if((Test-PathWithin $path $layout.Pkgs) -and (Test-ScienceCachePath $layout.Pkgs $path $memo $cacheStores)){continue}
        if($managed -and (Test-ScienceTransactionEvidencePath $layout $path $snapshot $memo)){continue}
        throw "Unidentified content will not be deleted: $path"
    }
    return [pscustomobject]@{Root=$root;Files=$snapshot;External=$external;Environments=@($Row.Environments|Sort-Object);
        Integration=$integration;Registry=$registry;RemoveRegistrations=$removeRegistrations}
}

function Get-ScienceCacheStores {
    param([string]$Cache,$Snapshot)
    $stores=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($candidate in $Snapshot.Keys){
        if(-not (Test-PathWithin $candidate $Cache) -or $candidate -ieq $Cache -or
           $candidate -notmatch '\\(?:https|http|file)\\.+\\[^\\]+\\info\\index\.json$'){continue}
        $package=Split-Path -Parent (Split-Path -Parent $candidate)
        $store=Split-Path -Parent $package
        if($store -ine $Cache){[void]$stores.Add($store)}
    }
    return ,$stores
}

function Test-ScienceCachePath {
    param([string]$Cache,[string]$Path,$Memo,$Stores)
    foreach($store in $Stores){
        if($Path -ieq $store -or (Test-PathWithin $store $Path)){return $true}
        if(Test-PathWithin $Path $store){return Test-ScienceCacheEntry $store $Path $Memo}
    }
    return Test-ScienceCacheEntry $Cache $Path $Memo
}

function Test-ScienceRemovalConfirmations {
    param([string]$Root,[bool]$Default,[scriptblock]$Reader={param($Prompt) Read-Host $Prompt})
    if(-not (Test-ScienceInteractiveConfiguration)){throw 'Whole-root removal requires an interactive console.'}
    if(-not $Default -and (& $Reader "Type the displayed root path exactly: $Root") -cne $Root){return $false}
    $phrase='Yes, I do understand.'
    if((& $Reader "Permanently remove this root and all listed environments? Type: $phrase") -cne $phrase){return $false}
    return ((& $Reader "Final confirmation for $Root. Type again: $phrase") -ceq $phrase)
}

function Select-ScienceTotalRoot {
    param($Inventory,[string]$ActivePrefix=$env:CONDA_PREFIX,[scriptblock]$Reader={param($Prompt) Read-Host $Prompt})
    $rows=@($Inventory.Roots)
    if(-not $rows.Count){return $null}
    $science=@($rows|Where-Object {$_.Environments -contains 'science'})
    $active=@($science|Where-Object {$_.VerifiedExecutable -and $_.Layout.Science -ieq $ActivePrefix})
    $default=0
    for($i=0;$i -lt $rows.Count;$i++){
        $item=$rows[$i]
        if(($active.Count -eq 1 -and $item.Root -ieq $active[0].Root) -or
           ($science.Count -eq 1 -and $item.Root -ieq $science[0].Root -and $item.VerifiedExecutable)){$default=$i+1}
        Write-Host ('[{0}] {1} | environments: {2} | executable verified: {3}' -f ($i+1),$item.Root,($item.Environments -join ', '),$item.VerifiedExecutable)
        if($item.Unknown.Count){Write-Host ('    Unknown: '+($item.Unknown -join '; '))}
    }
    foreach($path in $Inventory.External){Write-Host "Preserve external registered environment: $path"}
    $answer=([string](& $Reader "Select Micromamba root [$default]; 0 cancels")).Trim()
    if(-not $answer){$answer=[string]$default}
    if($answer -eq '0'){return $null}
    if($answer -notmatch '^[1-9]\d{0,2}$' -or [int]$answer -gt $rows.Count){throw 'Invalid root selection.'}
    return [pscustomobject]@{Row=$rows[[int]$answer-1];IsDefault=([int]$answer -eq $default)}
}

function Get-ScienceRemovalPlanDigest {
    param($Plan)
    $rows=@('ROOT '+$Plan.Root)+@($Plan.Environments | ForEach-Object {'ENV '+$_})+
        @($Plan.Files.Keys | Sort-Object | ForEach-Object {"FILE $_ $($Plan.Files[$_])"})+
        @($Plan.External.Keys | Sort-Object | ForEach-Object {"EXTERNAL $_ $($Plan.External[$_])"})+
        @($Plan.Integration.Keys | Sort-Object | ForEach-Object {"SETTING $_ "+($Plan.Integration[$_] -join [char]0)})+
        @($Plan.Registry.Digest)+@($Plan.RemoveRegistrations)
    return Get-ScienceTextDigest ($rows -join "`n")
}

function Invoke-ScienceTotalRemoval {
    param($Approved,[scriptblock]$Recheck)
    $seen=New-Object 'Collections.Generic.List[string]';$failed=$null
    $lockPath=Join-Path $Approved.Root '.science-update.lock'
    $lease=$null
    try{
        $plan=& $Recheck
        if((Get-ScienceRemovalPlanDigest $plan) -cne (Get-ScienceRemovalPlanDigest $Approved)){throw 'The inventory or file identities changed after approval.'}
        if($plan.Files.ContainsKey($lockPath)){
            $lease=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        }
        $order=@($plan.Files.Keys | Where-Object {$_ -ine $Approved.Root -and $_ -ine $lockPath} | Sort-Object -Property Length -Descending)
        foreach($path in $order){
            $failed=$path
            [ScienceRootNative]::Remove($path,$plan.Files[$path],$plan.Files)
            $seen.Add($path)
        }
        if($lease){
            $lease.Dispose();$lease=$null;$failed=$lockPath
            [ScienceRootNative]::Remove($lockPath,$plan.Files[$lockPath],$plan.Files)
            $seen.Add($lockPath)
        }
        $failed=$plan.Root
        [ScienceRootNative]::Remove($plan.Root,$plan.Files[$plan.Root],$plan.Files)
        $seen.Add($plan.Root)
        foreach($path in $plan.External.Keys){
            $failed=$path
            [ScienceRootNative]::Remove($path,$plan.External[$path],$plan.Files)
            $seen.Add($path)
        }
        if($plan.RemoveRegistrations.Count){
            $failed=$plan.Registry.Path
            $bytes=[IO.File]::ReadAllBytes($failed)
            if((Get-ScienceFileSha256 $failed) -ine $plan.Registry.Digest){throw 'Conda registry changed; registrations were preserved.'}
            $body=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
            $next=(($body -split '(?<=\n)' | Where-Object {$plan.RemoveRegistrations -notcontains $_.TrimEnd("`r","`n")}) -join '')
            Set-ScienceConfigBytes $failed ([Text.Encoding]::UTF8.GetBytes($next)) -ExpectedBytes $bytes
            $seen.Add("selected registrations in $failed")
        }
        foreach($key in $plan.Integration.Keys){
            $failed=$key
            $scope,$name=$key -split '/',2
            $old,$next=$plan.Integration[$key]
            if([Environment]::GetEnvironmentVariable($name,$scope) -ine $old){throw 'The environment variable changed after approval.'}
            [Environment]::SetEnvironmentVariable($name,$(if($next){$next}else{$null}),$scope)
            $seen.Add($key)
        }
        return [pscustomobject]@{Status='SUCCESS';Root=$plan.Root;Completed=$seen.Count;Incomplete=$null}
    }catch{
        return [pscustomobject]@{Status=$(if($seen.Count){'PARTIAL'}else{'BLOCKED'});Root=$Approved.Root;Completed=$seen.Count;
            EntriesCompleted=@($seen.ToArray());Incomplete=$failed;Error=$_.Exception.Message;
            Recovery='Keep the remaining files and inspect the first failure. Other roots are outside the deletion plan. No automatic rollback was attempted.'}
    }finally{if($lease){$lease.Dispose()}}
}
