[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath(),[string]$ActualPlanPath,[string]$ActualPrefix,[string]$ActualConfig,[string]$ActualMicromamba)
$ErrorActionPreference='Stop'
$TempRoot=[IO.Path]::GetFullPath($TempRoot)
$root=Split-Path $PSScriptRoot
$work=Join-Path $TempRoot ('removal-policy-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$env:TEMP=$work;$env:TMP=$work
. (Join-Path $root 'windows/science-release.ps1')
. (Join-Path $root 'windows/science-launcher-common.ps1')
. (Join-Path $root 'windows/science-update.ps1')
$results=New-Object Collections.Generic.List[object]
function Check {param([bool]$Value,[string]$Message='Assertion failed');if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body);try{& $Body;$results.Add(@{name=$Name;pass=$true});Write-Host "PASS $Name"}catch{$results.Add(@{name=$Name;pass=$false;error=$_.Exception.Message});Write-Host "FAIL ${Name}: $($_.Exception.Message)"}}
function Reject {param([scriptblock]$Body,[string]$Pattern);$caught=$null;try{$null=& $Body}catch{$caught=$_};Check ($null -ne $caught) 'Expected rejection';Check ($caught.Exception.Message -match $Pattern) ('Unexpected rejection: '+$caught.Exception.Message)}
function Put-Json {param([string]$Path,$Value);[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 32),(New-Object Text.UTF8Encoding($false)))}
function Record {param([string]$Name,[string]$Version='1.0',[string[]]$Depends=@(),[string]$Requested='')
    return [pscustomobject]@{name=$Name;version=$Version;build='0';build_number=0;subdir='noarch';sha256=('a'*64);depends=@($Depends);requested_spec=$Requested;url="https://example.test/noarch/$Name-$Version-0.tar.bz2"}
}
function Fixture {
    $path=Join-Path $work ([Guid]::NewGuid().ToString('N'));$prefix=Join-Path $path 'envs/science';$meta=Join-Path $prefix 'conda-meta';$tmp=Join-Path $path 'tmp'
    foreach($p in @($meta,$tmp)){[void][IO.Directory]::CreateDirectory($p)}
    $a=Record 'science-root' '1.0' @('science-dep >=1') 'science-root'
    $b=Record 'science-dep';$u=Record 'science-unowned'
    foreach($r in @($a,$b,$u)){Put-Json (Join-Path $meta ($r.name+'.json')) $r}
    [IO.File]::WriteAllText((Join-Path $meta 'history'),"# update specs: [`"science-root`"]`n")
    $config=Join-Path $path 'config.json';Put-Json $config ([pscustomobject]@{SchemaVersion=1;Channels=@('conda-forge');ScientificPackages=@('science-root')})
    $exe=Join-Path $path 'not-an-executable.txt';[IO.File]::WriteAllText($exe,'test-only')
    $a2=Record 'science-root' '2.0' @() 'science-root'
    $plan=[pscustomobject]@{success=$true;prefix=$prefix;actions=[pscustomobject]@{LINK=@($a2);UNLINK=@($a,$b)}}
    return [pscustomobject]@{Prefix=$prefix;Meta=$meta;Config=$config;Before=(Get-ScienceRecords $prefix);Plan=$plan;RootRecord=$a;NewRoot=$a2;Dep=$b;Unowned=$u;Layout=[pscustomobject]@{Root=$path;Science=$prefix;Tmp=$tmp;Pkgs=$tmp;Micromamba=$exe}}
}
$useFixture={
    $fixture=Fixture
    function Get-ScienceConfigurationPath {return $fixture.Config}
}
function Lock-Fixture {param($Fixture,[string[]]$Approved=@());return (New-ScienceApprovedLock $Fixture.Before $Fixture.Plan $Fixture.Prefix (Get-ScienceFileSha256 $Fixture.Config) (Get-ScienceFileSha256 $Fixture.Layout.Micromamba) @() $Approved)}
Case 'dependency-removal-is-distinct-from-upgrade' {
    . $useFixture
    $names=@(Get-ScienceRemovalCandidates $fixture.Before $fixture.Plan $fixture.Prefix)
    Check (($names -join '|') -ceq 'science-dep')
    Reject {Lock-Fixture $fixture} 'requires approval'
    $lock=Lock-Fixture $fixture $names
    Check (($lock.approved_removals -join '|') -ceq 'science-dep')
    Check (@($lock.after|Where-Object name -CEQ 'science-root').Count -eq 1)
    Check (@($lock.after|Where-Object name -CEQ 'science-unowned').Count -eq 1)
}
foreach($kind in @('upgrade','downgrade','build-replacement','reinstall')) {
    Case ('same-name-'+$kind+'-does-not-require-removal-approval') {
        . $useFixture
        $replacement=Record 'science-root' $(if($kind -ceq 'upgrade'){'2.0'}elseif($kind -ceq 'downgrade'){'0.9'}else{'1.0'}) @('science-dep >=1') 'science-root'
        if($kind -ceq 'build-replacement'){$replacement.build='1';$replacement.url='https://example.test/noarch/science-root-1.0-1.tar.bz2'}
        $fixture.Plan.actions.LINK=@($replacement);$fixture.Plan.actions.UNLINK=@($fixture.RootRecord)
        Check (@(Get-ScienceRemovalCandidates $fixture.Before $fixture.Plan $fixture.Prefix).Count -eq 0)
        $null=Lock-Fixture $fixture
    }
}
foreach($kind in @('current-request','requested-metadata','history-request','pinned','unknown-ownership','missing-requested-metadata','still-required','malformed-history','missing-history','empty-history','whole-environment','wrong-identity','wrong-prefix','wrong-approved-set')) {
    Case ('reject-'+$kind) {
        . $useFixture
        $pattern='protected|ownership|still required|history|complete Science|UNLINK|prefix|requires approval|Cannot|regular file'
        switch($kind) {
            current-request {$configuration=Read-ScienceJson $fixture.Config;$configuration.ScientificPackages+=@('science-dep');Put-Json $fixture.Config $configuration}
            requested-metadata {$fixture.Before['science-dep'].requested_spec='science-dep'}
            history-request {[IO.File]::AppendAllText((Join-Path $fixture.Meta 'history'),"# install specs: [`"science-dep`"]`n")}
            pinned {[IO.File]::WriteAllText((Join-Path $fixture.Meta 'pinned'),'science-dep=1.0')}
            unknown-ownership {$fixture.Plan.actions.UNLINK+=@($fixture.Unowned)}
            missing-requested-metadata {$fixture.Before['science-dep'].PSObject.Properties.Remove('requested_spec')}
            still-required {$fixture.Plan.actions.LINK[0].depends=@('science-dep >=1')}
            malformed-history {[IO.File]::WriteAllText((Join-Path $fixture.Meta 'history'),'# update specs: not-json')}
            empty-history {[IO.File]::WriteAllText((Join-Path $fixture.Meta 'history'),'# no recoverable requested specs')}
            missing-history {Remove-Item -LiteralPath (Join-Path $fixture.Meta 'history');$pattern='Cannot find path|does not exist'}
            whole-environment {$fixture.Plan.actions.LINK=@();$fixture.Plan.actions.UNLINK=@($fixture.Before.Values)}
            wrong-identity {$copy=$fixture.Dep|ConvertTo-Json -Depth 8|ConvertFrom-Json;$copy.sha256='b'*64;$fixture.Plan.actions.UNLINK=@($copy)}
            wrong-prefix {$fixture.Plan.prefix=Join-Path $work 'different-prefix'}
            wrong-approved-set {Reject {Lock-Fixture $fixture @('science-dep','unapproved')} $pattern;return}
        }
        Reject {Get-ScienceRemovalCandidates $fixture.Before $fixture.Plan $fixture.Prefix} $pattern
    }
}
Case 'foundation-removal-is-forbidden-even-without-user-request' {
    . $useFixture
    $python=Record 'python';$fixture.Before['python']=$python;$fixture.Before['science-root'].depends=@('python')
    $fixture.Plan.actions.UNLINK=@($python)
    Reject {Get-ScienceRemovalCandidates $fixture.Before $fixture.Plan $fixture.Prefix} 'protected package: python'
}
foreach($answers in @(@('','yes'),@('no','yes'),@('yes',''),@('yes','no'),@('yes','yes'))) {
    Case ('two-approval-gates-'+(($answers|ForEach-Object {if($_){$_}else{'default-no'}}) -join '-')) {
        . $useFixture
        $testState=@{Prompts=New-Object Collections.Generic.List[string];Boundary=0;Native=0;Answers=$answers}
        function Test-ScienceInteractiveConfiguration {return $true}
        function Read-Host {param([string]$Prompt);$index=$testState.Prompts.Count;$testState.Prompts.Add($Prompt);return $testState.Answers[$index]}
        function Invoke-ScienceNative {$testState.Native++;throw 'Forbidden native call'}
        function Invoke-ScienceLockedTransaction {param($Layout,$Lock,$Directory,$ConfigPath,$ExpectedLockDigest,$BeforeCommit)
            $testState.Boundary++;Check (($Lock.approved_removals -join '|') -ceq 'science-dep');Check ((Get-ScienceTextDigest ($Lock|ConvertTo-Json -Depth 64 -Compress)) -ceq $ExpectedLockDigest)
            throw 'TEST: execution boundary reached; nothing executed'
        }
        $caught=$null;try{Invoke-ScienceReviewedTransaction $fixture.Layout $fixture.Before $fixture.Plan $fixture.Config}catch{$caught=$_}
        Check ($null -ne $caught)
        $both=($answers[0] -ceq 'yes' -and $answers[1] -ceq 'yes')
        Check ($testState.Boundary -eq $(if($both){1}else{0})) ('Wrong boundary count: '+$caught.Exception.Message)
        Check ($testState.Native -eq 0)
        Check ($testState.Prompts.Count -eq $(if($answers[0] -ceq 'yes'){2}else{1}))
        Check ($testState.Prompts[0] -ceq 'Remove exactly these dependency packages? [y/N]')
        if($testState.Prompts.Count -eq 2){Check ($testState.Prompts[1] -ceq 'Apply exactly this transaction? [y/N]')}
        if(-not $both){Check (@(Get-ChildItem $fixture.Layout.Tmp).Count -eq 0) 'Staging occurred before both approvals'}
    }
}
Case 'noninteractive-operation-rejects-before-prompt-staging-or-native-call' {
    . $useFixture
    function Test-ScienceInteractiveConfiguration {return $false}
    function Read-Host {throw 'Unexpected prompt'}
    function Invoke-ScienceNative {throw 'Unexpected native call'}
    Check (-not (Confirm-ScienceDependencyRemovals @('science-dep') $fixture.Before))
    Check (-not (Confirm-ScienceTransaction @{} 'not-used'))
    Reject {Invoke-ScienceReviewedTransaction $fixture.Layout $fixture.Before $fixture.Plan $fixture.Config} 'Non-interactive'
    Check (@(Get-ChildItem $fixture.Layout.Tmp).Count -eq 0)
}
Case 'locked-removal-list-tampering-stops-before-staging' {
    . $useFixture
    $lock=Lock-Fixture $fixture @('science-dep');$lock.approved_removals=@()
    $identity=Get-ScienceTextDigest ($lock|ConvertTo-Json -Depth 64 -Compress)
    Reject {Invoke-ScienceLockedTransaction $fixture.Layout $lock (Join-Path $fixture.Layout.Tmp 'not-created') $fixture.Config $identity} 'Locked removals differ'
    Check (@(Get-ChildItem $fixture.Layout.Tmp).Count -eq 0)
}
Case 'pins-are-covered-by-the-prefix-digest' {
    . $useFixture
    $before=Get-SciencePrefixDigest $fixture.Prefix
    [IO.File]::WriteAllText((Join-Path $fixture.Meta 'pinned'),'science-root=1.0')
    Check ((Get-SciencePrefixDigest $fixture.Prefix) -cne $before)
}
if($ActualPlanPath) {
    Case 'actual-42-request-plan-lock-and-two-approval-boundaries' {
        $plan=Get-Content -LiteralPath $ActualPlanPath -Raw|ConvertFrom-Json
        $before=Get-ScienceRecords $ActualPrefix
        function Get-ScienceConfigurationPath {return $ActualConfig}
        $config=Read-ScienceJson $ActualConfig
        Check ($config.ScientificPackages.Count -eq 42);Check ($plan.success -and $plan.dry_run)
        $floors=Get-ScienceMediaFloors $before
        $null=Assert-SciencePlan $plan $before $floors $config.ScientificPackages
        $names=@(Get-ScienceRemovalCandidates $before $plan $ActualPrefix)
        Check (($names -join '|') -ceq 'backports.zstd|brotli-python|pysocks|win_inet_pton')
        $lock=New-ScienceApprovedLock $before $plan $ActualPrefix (Get-ScienceFileSha256 $ActualConfig) (Get-ScienceFileSha256 $ActualMicromamba) @() $names
        Check (($lock.approved_removals -join '|') -ceq ($names -join '|'))
        $testState=@{Prompts=New-Object Collections.Generic.List[string];Boundary=0;Native=0}
        function Test-ScienceInteractiveConfiguration {return $true}
        function Read-Host {param([string]$Prompt);$testState.Prompts.Add($Prompt);return 'yes'}
        function Invoke-ScienceNative {$testState.Native++;throw 'Forbidden actual native call'}
        function Invoke-ScienceLockedTransaction {$testState.Boundary++;throw 'TEST: stopped before actual native transaction'}
        $layout=[pscustomobject]@{Science=$ActualPrefix;Micromamba=$ActualMicromamba;Tmp=(Join-Path $work 'actual-plan-test')}
        Reject {Invoke-ScienceReviewedTransaction $layout $before $plan $ActualConfig} 'stopped before actual native transaction'
        Check ($testState.Prompts.Count -eq 2 -and $testState.Boundary -eq 1 -and $testState.Native -eq 0)
    }
}
$report=[ordered]@{powershell=$PSVersionTable.PSVersion.ToString();tests=$results.ToArray();failed=@($results|Where-Object {-not $_.pass}).Count;native_package_transactions=0;work=$work}
[IO.File]::WriteAllText((Join-Path $work 'results.json'),($report|ConvertTo-Json -Depth 8))
Write-Host ('RESULT tests='+$results.Count+' failed='+$report.failed+' evidence='+$work)
if($report.failed){exit 1}
