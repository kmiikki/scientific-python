[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath(),[string]$Micromamba,[string]$PackageArchive)
$ErrorActionPreference='Stop'
$base=Join-Path (Split-Path -Parent $PSScriptRoot) 'windows'
. (Join-Path $base 'science-common.ps1')
. (Join-Path $base 'science-release.ps1')
. (Join-Path $base 'science-launcher-common.ps1')
. (Join-Path $base 'science-update.ps1')
. (Join-Path $base 'science-root-removal.ps1')
Initialize-ScienceRootNative
$homeFixture=Join-Path $TempRoot ('science-total-fixture-'+[guid]::NewGuid().ToString('n'))
$null=[IO.Directory]::CreateDirectory($homeFixture)
$caseCount=0
$skipped=0
function Assert-True($condition,$message){if(-not $condition){throw $message}}
function Expect-Block([scriptblock]$Call,[string]$Pattern){
    $problem=$null;try{$null=& $Call}catch{$problem=$_.Exception.Message}
    if(-not $problem -or $problem -notmatch $Pattern){throw "Expected $Pattern, got: $problem"}
}
function Write-Fixture([string]$Path,[string]$Text){
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text)
}
function Add-FixturePrefix([string]$Prefix){
    Write-Fixture (Join-Path $Prefix 'conda-meta/history') '+conda-forge::fixture-1.0-h0_0'
    Write-Fixture (Join-Path $Prefix 'conda-meta/fixture-1.0-h0_0.json') '{"name":"fixture","version":"1.0","build":"h0_0","files":["bin/fixture.txt"]}'
    Write-Fixture (Join-Path $Prefix 'bin/fixture.txt') 'package payload'
}
function New-FixtureRoot([string]$Name){
    $root=Join-Path $homeFixture $Name
    $exe=Join-Path $root 'bin/micromamba.exe'
    Write-Fixture $exe 'Inert unexecuted fixture binary'
    Add-FixturePrefix (Join-Path $root 'envs/science')
    Add-FixturePrefix (Join-Path $root 'envs/analysis')
    Write-Fixture (Join-Path $root 'pkgs/urls.txt') ''
    return [pscustomobject]@{Root=$root;Environments=@('science','analysis');Unknown=@();VerifiedExecutable=$true;
        Layout=[pscustomobject]@{Root=$root;Envs=(Join-Path $root 'envs');Science=(Join-Path $root 'envs/science');
            Pkgs=(Join-Path $root 'pkgs');Tmp=(Join-Path $root 'tmp');Micromamba=$exe}}
}
# Windows exercises native handles, junctions and effective deletion rights.
# Other hosts simulate those boundaries and still test the production planner.
$nativeWindows=[Environment]::OSVersion.Platform -eq 'Win32NT'
if(-not $nativeWindows){
    function Test-ScienceLocalRemovalVolume {param($Root);return $Root.StartsWith($homeFixture+[IO.Path]::DirectorySeparatorChar)}
    function Test-PathWithin {
        param([string]$Path,[string]$Base)
        return ($Path -and $Base -and ($Path -eq $Base -or $Path.StartsWith($Base.TrimEnd('/')+'/')))
    }
    function Get-ScienceRootSnapshot {
        param([string]$Root)
        $snapshot=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($path in @((Get-Item -LiteralPath $Root))+@(Get-ChildItem -LiteralPath $Root -Recurse -Force)){
            $snapshot.Add($path.FullName,"fixture:$($path.LastWriteTimeUtc.Ticks)")
        }
        return ,$snapshot
    }
}
function Assert-ScienceRootProcesses {if($script:Busy){throw 'active process fixture'}}
function Test-ScienceInteractiveConfiguration {return $script:Interactive}
function Get-ScienceCleanupSetting {
    param([string]$Name,[string]$Scope)
    if($Scope -eq 'Process'){return [Environment]::GetEnvironmentVariable($Name,$Scope)}
}
function Get-ScienceCleanupConfigDirectories { $homeFixture }
$script:Interactive=$true
$script:Busy=$false
$oldVars=@{}
foreach($name in 'CONDA_PREFIX','CONDA_PKGS_DIRS','MAMBA_PKGS_DIRS','MAMBA_ROOT_PREFIX','MAMBA_EXE','CONDA_ENVS_PATH','CONDA_ENVS_DIRS','MAMBA_ENVS_DIRS','CONDARC','MAMBARC'){
    $oldVars[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
    [Environment]::SetEnvironmentVariable($name,$null,'Process')
}
try{
    $selected=New-FixtureRoot 'selected'
    $other=New-FixtureRoot 'other'
    $external=Join-Path $homeFixture 'external'
    Add-FixturePrefix $external
    $registry=Join-Path $homeFixture '.conda\environments.txt'
    Write-Fixture $registry ($selected.Layout.Science+"`n"+$external+"`n"+$other.Layout.Science+"`n")
    $hash=(Get-FileHash -LiteralPath $selected.Layout.Micromamba -Algorithm SHA256).Hash
    $inv=[pscustomobject]@{Roots=@($selected,$other);Problems=@();Registry=[pscustomobject]@{Path=$registry;
        Paths=@($selected.Layout.Science,$external,$other.Layout.Science);Digest=(Get-FileHash -LiteralPath $registry -Algorithm SHA256).Hash}}
    $make={Get-ScienceTotalRemovalPlan $selected $inv $hash}
    Assert-True (-not (Select-ScienceTotalRoot $inv -ActivePrefix '' -Reader {''})) 'Ambiguous roots got a default.'
    $choice=Select-ScienceTotalRoot $inv -ActivePrefix $other.Layout.Science -Reader {''}
    Assert-True ($choice.Row.Root -eq $other.Root -and $choice.IsDefault) 'Active root was not the default.'
    $choice=Select-ScienceTotalRoot $inv -ActivePrefix $other.Layout.Science -Reader {'1'}
    Assert-True ($choice.Row.Root -eq $selected.Root -and -not $choice.IsDefault) 'Explicit root number failed.'
    $caseCount++
    $phrase='Yes, I do understand.'
    $queue=New-Object 'Collections.Generic.Queue[string]'
    $reader={param($Prompt) $queue.Dequeue()}
    foreach($responses in @(@($selected.Root+' '),@($selected.Root,'yes, I do understand.'),@($selected.Root,$phrase,$phrase.TrimEnd('.')))){
        $queue.Clear();foreach($answer in $responses){$queue.Enqueue($answer)}
        Assert-True (-not (Test-ScienceRemovalConfirmations $selected.Root $false $reader)) 'Incorrect confirmation accepted.'
    }
    $queue.Clear();$queue.Enqueue($selected.Root);$queue.Enqueue($phrase);$queue.Enqueue($phrase)
    Assert-True (Test-ScienceRemovalConfirmations $selected.Root $false $reader) 'Exact confirmations rejected.'
    $script:Interactive=$false
    Expect-Block {Test-ScienceRemovalConfirmations $selected.Root $true $reader} 'interactive'
    $script:Interactive=$true
    $caseCount++

    $script:Busy=$true;Expect-Block $make 'active process';$script:Busy=$false
    $oldValue=$env:CONDA_PKGS_DIRS;$env:CONDA_PKGS_DIRS=$other.Layout.Pkgs
    Expect-Block $make 'shared cache';$env:CONDA_PKGS_DIRS=$oldValue
    $caseCount++
    $extra=Join-Path $selected.Layout.Science 'user.ipynb'
    Write-Fixture $extra 'not package-owned'
    Write-Fixture (Join-Path $selected.Root '.inventory-fixture-marker') 'root notes'
    Write-Fixture (Join-Path $selected.Layout.Envs 'scratch/.message.txt') 'test data'
    $selected.Unknown=@('scratch')
    if($nativeWindows){
        $acl=Get-Acl -LiteralPath $extra
        $users=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        $grant=[Security.AccessControl.FileSystemAccessRule]::new($users,'Write','Allow')
        $acl.AddAccessRule($grant)
        Set-Acl -LiteralPath $extra -AclObject $acl
    }
    $plan=& $make
    Assert-True ($plan.Files.ContainsKey($extra)) 'User payload or additional ACL prevented whole-root planning.'
    $caseCount++
    $selected.VerifiedExecutable=$false
    Expect-Block $make 'trusted release hash'
    $selected.VerifiedExecutable=$true
    $caseCount++
    if(-not $nativeWindows){
        $changed=Join-Path $selected.Root 'new-after-approval.txt'
        Write-Fixture $changed 'late'
        $report=Invoke-ScienceTotalRemoval $plan $make
        Assert-True ($report.Status -eq 'BLOCKED' -and [IO.File]::Exists($extra) -and
            [IO.File]::Exists($changed)) 'Changed plan reached the native delete boundary.'
        $caseCount++
        Write-Host "PASS simulated Windows whole-root fixture groups: $caseCount"
        Write-Host 'SKIP native NTFS ACL, junction, open handles and deletion require Windows.'
        return
    }
    $junction=Join-Path $selected.Root 'redirected'
    try{$null=New-Item -ItemType Junction -Path $junction -Target $other.Root -ErrorAction Stop}
    catch{
        if($_.Exception -isnot [UnauthorizedAccessException] -and $_.Exception.Message -notmatch 'Access is denied'){throw}
        $skipped++;Write-Host 'SKIP junction creation denied by this execution context.'
    }
    if(Test-Path -LiteralPath $junction){
        try{Expect-Block $make 'Reparse point'}finally{[IO.Directory]::Delete($junction)}
        $caseCount++
    }
    $lock=Join-Path $selected.Layout.Science 'bin\fixture.txt'
    $stream=[IO.File]::Open($lock,'Open','ReadWrite','None')
    try{Expect-Block $make 'fixture.txt'}finally{$stream.Dispose()}
    $caseCount++
    $plan=& $make
    Assert-True (($plan.Environments -join ',') -ceq 'analysis,science') 'Unexpected planned environments.'
    Write-Fixture $lock 'updated payload'
    $blocked=Invoke-ScienceTotalRemoval $plan $make
    Assert-True ($blocked.Status -eq 'BLOCKED' -and [IO.Directory]::Exists($selected.Root)) 'Changed file did not stop removal.'
    $caseCount++
    [IO.File]::SetAttributes($lock,[IO.FileAttributes]::ReadOnly)
    try{Expect-Block $make 'Read-only file'}finally{[IO.File]::SetAttributes($lock,[IO.FileAttributes]::Normal)}
    $caseCount++
    $plan=& $make
    $result=Invoke-ScienceTotalRemoval $plan $make
    Assert-True ($result.Status -eq 'SUCCESS') ($result | ConvertTo-Json -Depth 6)
    Assert-True (-not [IO.Directory]::Exists($selected.Root)) 'Selected root remained after removal.'
    Assert-True ([IO.File]::Exists((Join-Path $other.Layout.Science 'bin\fixture.txt'))) 'Other root changed.'
    Assert-True ([IO.File]::Exists((Join-Path $external 'bin\fixture.txt'))) 'External prefix changed.'
    Assert-True (([IO.File]::ReadAllText($registry)) -ceq ($external+"`n"+$other.Layout.Science+"`n")) 'Registry preservation failed.'
    $recreated=New-FixtureRoot 'selected'
    Assert-True ([IO.File]::Exists($recreated.Layout.Micromamba)) 'A fresh root could not be created.'
    $caseCount++
    $inv.Registry.Paths=@()
    $plan=& $make
    $during=Join-Path $selected.Root 'unexpected-late.txt'
    $partial=Invoke-ScienceTotalRemoval $plan {
        $rechecked=& $make
        Write-Fixture $during 'late content'
        $rechecked
    }
    Assert-True ($partial.Status -eq 'PARTIAL' -and $partial.Completed -gt 0 -and $partial.Incomplete -eq $selected.Root) 'Partial failure was not attributed to the selected root.'
    Assert-True ([IO.File]::Exists($during)) 'Late content was deleted.'
    $caseCount++
    if($Micromamba -or $PackageArchive){
        if(-not $Micromamba -or -not $PackageArchive){throw 'Provide both Micromamba and PackageArchive.'}
        $real=Join-Path $homeFixture 'native'
        $realBin=Join-Path $real 'bin\micromamba.exe'
        $runnerExe=Join-Path $homeFixture 'fixture-runner.exe'
        $testUser=Join-Path $homeFixture 'native-user'
        [void][IO.Directory]::CreateDirectory($testUser)
        [IO.File]::Copy($Micromamba,$runnerExe)
        if((Get-FileHash -LiteralPath $runnerExe).Hash -ine $ScienceRelease.MicromambaSha256){throw 'Untrusted native fixture binary.'}
        $localArchive=Join-Path $homeFixture 'science-fixture-b-1.0-0.tar.bz2'
        [IO.File]::Copy($PackageArchive,$localArchive)
        $explicit=Join-Path $homeFixture 'explicit.txt'
        [IO.File]::WriteAllLines($explicit,@('@EXPLICIT',([uri]$localArchive).AbsoluteUri))
        $cachePath=Join-Path $real 'pkgs'
        $envMap=@{USERPROFILE=$testUser;HOME=$testUser;APPDATA=$testUser;LOCALAPPDATA=$testUser;MAMBA_ROOT_PREFIX=$real;CONDA_PKGS_DIRS=$cachePath}
        foreach($name in 'base','science','analysis'){
            $prefix=if($name -eq 'base'){$real}else{Join-Path $real "envs\$name"}
            $native=Invoke-ScienceNative $runnerExe @('create','--no-rc','--offline','--no-pyc','--json','--yes','-r',$real,'-p',$prefix,'--file',$explicit) $envMap
            if($native.ExitCode -or -not ($native.Stdout|ConvertFrom-Json).success){throw "Native fixture create failed for ${name}: exit $($native.ExitCode) $($native.Stderr) $($native.Stdout)"}
        }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $realBin))
        [IO.File]::Copy($Micromamba,$realBin)
        $oldRoot=$env:MAMBA_ROOT_PREFIX;$oldExe=$env:MAMBA_EXE
        $env:MAMBA_ROOT_PREFIX=$real;$env:MAMBA_EXE=$realBin
        function Get-ScienceLayoutStatuses {return @()}
        try{
            $makeNative={
                $discovered=Get-ScienceCleanupInventory $ScienceRelease.MicromambaSha256 -RegistryHome $testUser
                $target=@($discovered.Roots|Where-Object Root -eq $real)
                Assert-True ($target.Count -eq 1 -and $target[0].Environments.Count -eq 3 -and $target[0].Environments -contains 'base') 'Native fixture inventory did not find base and both named environments.'
                Get-ScienceTotalRemovalPlan $target[0] $discovered $ScienceRelease.MicromambaSha256
            }
            $reviewed=& $makeNative
            $removed=Invoke-ScienceTotalRemoval $reviewed $makeNative
            Assert-True ($removed.Status -eq 'SUCCESS') ($removed|ConvertTo-Json -Depth 5)
            Assert-True (-not [IO.Directory]::Exists($real)) 'Native fixture root was not removed.'
            Assert-True ([IO.File]::Exists($localArchive)) 'Source archive was removed with the cache.'
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $realBin))
            [IO.File]::Copy($Micromamba,$realBin)
            $fresh=Invoke-ScienceNative $realBin @('create','--no-rc','--offline','--no-pyc','--json','--yes','-r',$real,'-p',(Join-Path $real 'envs\science'),'--file',$explicit) $envMap
            Assert-True ($fresh.ExitCode -eq 0 -and ($fresh.Stdout|ConvertFrom-Json).success) 'Native fresh install after complete deletion failed.'
            $caseCount++
        }finally{$env:MAMBA_ROOT_PREFIX=$oldRoot;$env:MAMBA_EXE=$oldExe}
    }
    Write-Host "PASS Windows whole-root fixture groups: $caseCount; skipped: $skipped"
}finally{
    foreach($name in $oldVars.Keys){[Environment]::SetEnvironmentVariable($name,$oldVars[$name],'Process')}
    $resolved=[IO.Path]::GetFullPath($homeFixture)
    if($resolved.StartsWith(([IO.Path]::GetFullPath($TempRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar+'science-total-fixture-'),[StringComparison]::OrdinalIgnoreCase)){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
