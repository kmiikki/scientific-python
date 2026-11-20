# Loaded only after the source bundle has been verified.
function Initialize-ScienceRootNative {
    if(-not ('ScienceRootNative' -as [type])){
        Add-Type -Path (Join-Path $PSScriptRoot 'science-root-native.cs') -ErrorAction Stop
    }
}

function Get-ScienceRootSnapshot {
    param([string]$Root)
    $result=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $pending=New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while($pending.Count){
        $item=$pending.Pop()
        if($result.Count -ge 300000){throw 'Removal inventory exceeded 300,000 entries.'}
        $anchor=[ScienceRootNative+Anchor]::new($item,$result)
        try {
            $sig=[ScienceRootNative]::Inspect($item,$true)
            $result.Add($item,$sig)
            if([Convert]::ToUInt32(($sig -split ':')[2],16) -band 16){
                foreach($child in [IO.Directory]::EnumerateFileSystemEntries($item)){$pending.Push($child)}
            }
        } finally {$anchor.Dispose()}
    }
    return ,$result
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
        if($entry -ine $Root -and (Test-PathWithin $Root $entry)){
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

function Test-ScienceLocalRemovalVolume {
    param([string]$Root)
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($Root))
    return ($drive.DriveType -eq 'Fixed' -and $drive.DriveFormat -eq 'NTFS' -and $Root -ine $drive.RootDirectory.FullName)
}

function Get-ScienceTotalRemovalPlan {
    param($Row,$Inventory,[string]$ExpectedSha256)
    Initialize-ScienceRootNative
    $layout=$Row.Layout
    $root=$layout.Root
    $profiles=[IO.Path]::GetDirectoryName($HOME)
    if(-not (Test-ScienceLocalRemovalVolume $root) -or
       $root -cne ([IO.Path]::GetFullPath($root)) -or (Test-PathWithin $HOME $root) -or
       (Test-PathWithin $PSScriptRoot $root) -or
       ($root -ieq $layout.ParentRoot) -or ($profiles -and (Test-PathWithin $root $profiles) -and -not (Test-PathWithin $root $HOME))){
        throw 'Select a dedicated local NTFS directory separate from system paths, profiles and the running installer.'
    }
    foreach($protected in @($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,'C:\micromamba')){
        if($protected -and ($root -ieq $protected -or ($protected -ine 'C:\micromamba' -and (Test-PathWithin $root $protected)))){
            throw "Protected system or shared root: $protected"
        }
    }
    if(@($Inventory.Problems).Count){throw 'Incomplete registry or root inventory prevents proving the deletion scope.'}
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
        Assert-ScienceLayoutStateIdentity $layout $state
        $managed=$state.schema_version -eq 2 -and $state.user_sid -ceq $layout.Sid -and
                 $state.root -ieq $root -and $state.micromamba -ieq $layout.Micromamba -and
                 $state.root_existed_before -is [bool] -and -not $state.root_existed_before -and
                 $state.micromamba_existed_before -is [bool] -and -not $state.micromamba_existed_before
    }
    if(-not ($managed -or $Row.Environments.Count -or [IO.Directory]::Exists($layout.Pkgs))){
        throw 'The executable is recognized, but this directory has no Micromamba root layout.'
    }
    $registry=$Inventory.Registry
    $removeRegistrations=@($registry.Paths | Where-Object {Test-PathWithin $_ $root})
    if($removeRegistrations.Count){
        Assert-ScienceRegularPath $registry.Path
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
            if(($supportedConfig.Count -eq 1 -or $path -ieq $layout.Config) -and [IO.File]::Exists($path)){
                Assert-ScienceRegularPath $path
                if([IO.File]::ReadAllText($path).Trim() -ceq 'use_sharded_repodata: false'){continue}
            }
            if([IO.File]::Exists($path) -and (Test-ScienceChannelOnlyConfig $path)){
                continue
            }
            throw "A custom configuration may share resources: $path"
        }
    }
    Assert-ScienceRootProcesses $root $layout.Micromamba
    $snapshot=Get-ScienceRootSnapshot $root
    if($state -and $state.root_file_identity -and $state.root_file_identity -cne $snapshot[$root].Substring(0,26)){
        throw 'Root directory identity disagrees with the installer state.'
    }
    Assert-ScienceRegularPath $layout.Micromamba
    if((Get-FileHash -LiteralPath $layout.Micromamba -Algorithm SHA256 -ErrorAction Stop).Hash -ine $ExpectedSha256){throw 'Micromamba changed during planning.'}
    if($managed -and (Test-PathWithin $layout.Bin $root) -and
       $state.bin_path_existed_before -is [bool] -and -not $state.bin_path_existed_before){
        $pathValue=Get-ScienceCleanupSetting 'Path' 'User'
        if($pathValue){
            $nextPath=(($pathValue -split ';') | Where-Object {$_ -ine $layout.Bin}) -join ';'
            if($nextPath -cne $pathValue){$integration['User/Path']=@($pathValue,$nextPath)}
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
    return [pscustomobject]@{Root=$root;Files=$snapshot;Environments=@($Row.Environments|Sort-Object);
        Integration=$integration;Registry=$registry;RemoveRegistrations=$removeRegistrations}
}

function Test-ScienceRemovalConfirmations {
    param([string]$Root,[bool]$Default,[scriptblock]$Reader={param($Prompt) Read-Host $Prompt})
    if(-not (Test-ScienceInteractiveConfiguration)){throw 'Whole-root removal requires an interactive console.'}
    if(-not $Default -and (& $Reader "Type the displayed directory path exactly: $Root") -cne $Root){return $false}
    $phrase='Yes, I do understand.'
    if((& $Reader "First confirmation for ${Root}. Type: $phrase") -cne $phrase){return $false}
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
    $answer=([string](& $Reader "Select Micromamba directory [$default]; 0 cancels")).Trim()
    if(-not $answer){$answer=[string]$default}
    if($answer -eq '0'){return $null}
    if($answer -notmatch '^[1-9]\d{0,2}$' -or [int]$answer -gt $rows.Count){throw 'Invalid root selection.'}
    return [pscustomobject]@{Row=$rows[[int]$answer-1];IsDefault=([int]$answer -eq $default)}
}

function Get-ScienceRemovalPlanDigest {
    param($Plan)
    $rows=@('ROOT '+$Plan.Root)+@($Plan.Environments | ForEach-Object {'ENV '+$_})+
        @($Plan.Files.Keys | Sort-Object | ForEach-Object {"FILE $_ $($Plan.Files[$_])"})+
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
