[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath())
# Installer helpers belong to a caller scope, not the global session. Reproduce
# that ownership so a GetNewClosure callback cannot accidentally use globals.
& {
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$work=Join-Path ([IO.Path]::GetFullPath($TempRoot)) ('callback-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$env:TEMP=$work;$env:TMP=$work
. (Join-Path $root 'windows/science-release.ps1')
. (Join-Path $root 'windows/science-launcher-common.ps1')
. (Join-Path $root 'windows/science-update.ps1')
$results=New-Object Collections.Generic.List[object]
function Check {param([bool]$Value,[string]$Message='Assertion failed');if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body);try{& $Body;$results.Add(@{name=$Name;pass=$true});Write-Host "PASS $Name"}catch{$results.Add(@{name=$Name;pass=$false;error=$_.Exception.Message;stack=$_.ScriptStackTrace});Write-Host "FAIL ${Name}: $($_.Exception.Message)"}}
function Reject {param([scriptblock]$Body,[string]$Pattern);$caught=$null;try{$null=& $Body}catch{$caught=$_};Check ($null -ne $caught) 'Expected rejection';Check ($caught.Exception.Message -match $Pattern) ('Wrong rejection: '+$caught.Exception.Message)}
function Put-Json {param([string]$Path,$Value);[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 64),(New-Object Text.UTF8Encoding($false)))}
function Fixture {
    $dir=Join-Path $work ([Guid]::NewGuid().ToString('N'));$prefix=Join-Path $dir 'envs/science';$meta=Join-Path $prefix 'conda-meta'
    $layout=[pscustomobject]@{Root=$dir;Science=$prefix;Tmp=(Join-Path $dir 'tmp');Pkgs=(Join-Path $dir 'pkgs');Micromamba=(Join-Path $dir 'fake-native.txt')}
    foreach($p in @($meta,$layout.Tmp,$layout.Pkgs,(Join-Path $prefix 'Scripts'))){[void][IO.Directory]::CreateDirectory($p)}
    [IO.File]::WriteAllText($layout.Micromamba,'never executed')
    $records=@{}
    foreach($entry in @(@('science-root','1.0'),@('science-root','2.0'),@('science-dep','1.0'),@('librsvg','2.62.3'))) {
        $name=$entry[0];$version=$entry[1];$filename="$name-$version-0.tar.bz2";$path=Join-Path $layout.Pkgs $filename
        [IO.File]::WriteAllText($path,('test bytes '+$filename))
        $records[($name+'-'+$version)]=[pscustomobject]@{name=$name;version=$version;build='0';build_number=0;subdir='noarch';sha256=(Get-ScienceFileSha256 $path);depends=@();requested_spec='';url=('https://example.test/noarch/'+$filename);fn=$filename}
    }
    $old=$records['science-root-1.0'];$old.depends=@('science-dep >=1');$old.requested_spec='science-root'
    $new=$records['science-root-2.0'];$new.requested_spec='science-root'
    foreach($r in @($old,$records['science-dep-1.0'],$records['librsvg-2.62.3'])){Put-Json (Join-Path $meta ($r.name+'.json')) $r}
    [IO.File]::WriteAllText((Join-Path $meta 'history'),"# update specs: [`"science-root`"]`n")
    $config=Join-Path $dir 'config.json';Put-Json $config ([pscustomobject]@{SchemaVersion=1;Channels=@('conda-forge');ScientificPackages=@('science-root')})
    # Approved legacy hook bytes, SHA256 d6c9e6a1...f3fdc. Never execute this fixture.
    $hook=Join-Path $prefix 'Scripts/.librsvg-pre-unlink.bat'
    $bytes=[Convert]::FromBase64String('c2V0IEdES19QSVhCVUZfUE9TVF9MSU5LX1NDUklQVD0lUFJFRklYJVxTY3JpcHRzXC5nZGstcGl4YnVmLXBvc3QtbGluay5iYXQNCmlmIG5vdCBleGlzdCAiJUdES19QSVhCVUZfUE9TVF9MSU5LX1NDUklQVCUiIGV4aXQgMA0KDQo6OiBTaW5jZSBsaWJyc3ZnIGlzIGJlaW5nIHJlbW92ZWQsIHdlIHdhbnQgaXQgdG8gYmUgcmVtb3ZlZCBmcm9tIGxvYWRlcnMuY2FjaGUuDQo6OiBCdXQgc2luY2UgdGhpcyBpcyBhIFBSRS11bmxpbmsgc2NyaXB0LCB0aGUgbG9hZGVyIGlzIHN0aWxsIHByZXNlbnQuDQo6OiBSZW1vdmUgaXQgbm93IHNvIHdlIGNhbiB1cGRhdGUgbG9hZGVycy5jYWNoZSBjb3JyZWN0bHkuDQpjZCAiJVBSRUZJWCVcTGlicmFyeVxsaWJcZ2RrLXBpeGJ1Zi0yLjAiID4gbnVsIDI+PiAiJVBSRUZJWCUvLm1lc3NhZ2VzLnR4dCINCmlmIGVycm9ybGV2ZWwgMSBleGl0IDENCg0KZGVsIC9GIC9TIC9RICJsaWJwaXhidWZsb2FkZXItc3ZnLmRsbCIgPiBudWwgMj4+ICIlUFJFRklYJS8ubWVzc2FnZXMudHh0Ig0KaWYgZXJyb3JsZXZlbCAxIGV4aXQgMQ0KDQo6OiBUaGUgZ2RrLXBpeGJ1ZiBwb3N0LWxpbmsgZnVuY3Rpb24gdXBkYXRlcyB0aGUgbG9hZGVycw0KY2FsbCAiJUdES19QSVhCVUZfUE9TVF9MSU5LX1NDUklQVCUiDQo=')
    [IO.File]::WriteAllBytes($hook,$bytes)
    Check ((Get-ScienceFileSha256 $hook) -ceq 'd6c9e6a1e396bf30d91cd2e1ed57b49050799f0f22d672f63932b30dfc9f3fdc')
    $plan=[pscustomobject]@{success=$true;prefix=$prefix;actions=[pscustomobject]@{LINK=@($new);UNLINK=@($old,$records['science-dep-1.0'])}}
    return [pscustomobject]@{Layout=$layout;Config=$config;Plan=$plan;Before=(Get-ScienceRecords $prefix);New=$new;Hook=$hook;HookHash=(Get-ScienceFileSha256 $hook)}
}
$setup={
    $fixture=Fixture
    $callbackTestState=@{Mode='idle';NativeCalls=0;CommitCalls=0;CimCalls=0;GuardObserved=$false;Prompts=New-Object Collections.Generic.List[string]}
    function Get-ScienceConfigurationPath {return $fixture.Config}
    function Test-ScienceInteractiveConfiguration {return ($callbackTestState.Mode -cne 'noninteractive')}
    function Read-Host {param([string]$Prompt)
        $callbackTestState.Prompts.Add($Prompt)
        if($callbackTestState.Mode -ceq 'reject-removals' -and $Prompt.StartsWith('Remove exactly')){return 'no'}
        if($callbackTestState.Mode -ceq 'reject-full' -and $Prompt.StartsWith('Apply exactly')){return 'no'}
        return 'yes'
    }
    function Get-CimInstance {param($ClassName,$ErrorAction)
        $callbackTestState.CimCalls++
        if($callbackTestState.Mode -ceq 'busy'){return [pscustomobject]@{ExecutablePath=($fixture.Layout.Science+'\python.exe')}}
        if($callbackTestState.Mode -ceq 'tamper-config'){[IO.File]::AppendAllText($fixture.Config,' ')}
        return @()
    }
    # Only native execution is simulated. The reviewed wrapper, locked executor,
    # archive SHA checks, preflight, actual callback helpers and cleanup are real.
    function Invoke-ScienceNative {param([string]$Executable,[string[]]$Arguments,[hashtable]$Environment)
        $callbackTestState.NativeCalls++
        $target=$Arguments[[Array]::IndexOf($Arguments,'-p')+1]
        if($Arguments -ccontains '--download-only') {
            return @{ExitCode=0;Stdout=([pscustomobject]@{success=$true;prefix=$target;actions=[pscustomobject]@{LINK=$fixture.Plan.actions.LINK;UNLINK=@()}}|ConvertTo-Json -Depth 64);Stderr=''}
        }
        if($Arguments -ccontains '--dry-run') {
            $preflight=$fixture.Plan|ConvertTo-Json -Depth 64|ConvertFrom-Json
            if($callbackTestState.Mode -ceq 'wrong-preflight'){$preflight.actions.LINK[0].sha256='b'*64}
            return @{ExitCode=0;Stdout=($preflight|ConvertTo-Json -Depth 64);Stderr=''}
        }
        Check ($Arguments -ccontains '-y') 'Unexpected native execution path'
        $callbackTestState.CommitCalls++
        Check ($callbackTestState.CimCalls -eq 1) 'In-use protection was not executed by the callback'
        $callbackTestState.GuardObserved=(Get-ScienceFileSha256 $fixture.Hook) -cne $fixture.HookHash
        Check $callbackTestState.GuardObserved 'GTK guard was not initialized before commit'
        if($callbackTestState.Mode -ceq 'commit-failure'){return @{ExitCode=9;Stdout='simulated native failure';Stderr='simulated native stderr'}}
        foreach($r in $fixture.Plan.actions.UNLINK){Remove-Item -LiteralPath (Join-Path $fixture.Layout.Science ('conda-meta/'+$r.name+'.json'))}
        foreach($r in $fixture.Plan.actions.LINK){Put-Json (Join-Path $fixture.Layout.Science ('conda-meta/'+$r.name+'.json')) $r}
        return @{ExitCode=0;Stdout=($fixture.Plan|ConvertTo-Json -Depth 64);Stderr=''}
    }
}
function Review-Fixture {
    param($Fixture,[scriptblock]$VerifyPackages)
    Invoke-ScienceReviewedTransaction $Fixture.Layout $Fixture.Before $Fixture.Plan $Fixture.Config -VerifyPackages $VerifyPackages
}
function Check-HookRestored {param($Fixture);Check ((Get-ScienceFileSha256 $Fixture.Hook) -ceq $Fixture.HookHash) 'GTK hook not restored';Check (@(Get-ChildItem $Fixture.Layout.Tmp -Filter 'librsvg-hook-*.original').Count -eq 0) 'GTK backup not cleaned'}
Case 'actual-executor-idle-callback-resolves-all-helpers-and-restores-gtk' {
    . $setup
    Review-Fixture $fixture {
        Check ($callbackTestState.CommitCalls -eq 1) 'Final verification ran before the commit'
        Check-HookRestored $fixture
        Check ((Get-ScienceRecords $fixture.Layout.Science)['science-root'].version -ceq '2.0')
        $callbackTestState.Verified=$true
    }
    Check $callbackTestState.Verified 'The installed package verification was not called'
    Check ($callbackTestState.CommitCalls -eq 1 -and $callbackTestState.NativeCalls -eq 3)
    Check ($callbackTestState.GuardObserved -and $callbackTestState.Prompts.Count -eq 2)
    Check-HookRestored $fixture
    Check ((Get-ScienceRecords $fixture.Layout.Science)['science-root'].version -ceq '2.0')
}
Case 'final-package-verification-error-propagates-without-retry' {
    . $setup
    Reject {Review-Fixture $fixture {throw 'fixture final package verification failure'}} 'fixture final package verification failure'
    Check ($callbackTestState.CommitCalls -eq 1 -and $callbackTestState.NativeCalls -eq 3)
    Check-HookRestored $fixture
}
Case 'legacy-getnewclosure-reproduces-helper-visibility-failure-before-commit' {
    . $setup
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'windows/science-update.ps1'),[ref]$tokens,[ref]$errors)
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-ScienceReviewedTransaction'},$true)
    $call='        $null=Invoke-ScienceLockedTransaction'
    $legacy=$node.Extent.Text.Replace($call,('        $callback=$callback.GetNewClosure()'+[Environment]::NewLine+$call))
    Check ($legacy -cne $node.Extent.Text) 'Legacy callback substitution did not take effect'
    . ([scriptblock]::Create($legacy))
    Reject {Review-Fixture $fixture} 'Assert-ScienceNotInUse.*not recognized'
    Check ($callbackTestState.CommitCalls -eq 0 -and $callbackTestState.CimCalls -eq 0)
    Check-HookRestored $fixture
}
foreach($mode in @('busy','tamper-config','commit-failure','wrong-preflight','reject-removals','reject-full','noninteractive','unreviewed-hook')) {
    Case ('real-executor-fails-safely-'+$mode) {
        . $setup;$callbackTestState.Mode=$mode
        $pattern=switch($mode){busy{'Close Science'};tamper-config{'Active configuration changed'};commit-failure{'Locked commit failed \(exit 9\)'};wrong-preflight{'differs from the approved LINK'};reject-removals{'Dependency removals cancelled'};reject-full{'Transaction cancelled'};noninteractive{'Non-interactive'};unreviewed-hook{'Unreviewed librsvg'}}
        if($mode -ceq 'unreviewed-hook'){[IO.File]::AppendAllText($fixture.Hook,'unreviewed');$fixture.HookHash=Get-ScienceFileSha256 $fixture.Hook}
        Reject {Review-Fixture $fixture} $pattern
        Check ($callbackTestState.CommitCalls -eq $(if($mode -ceq 'commit-failure'){1}else{0})) 'Wrong commit boundary count'
        Check-HookRestored $fixture
        if($mode -In @('reject-removals','reject-full','noninteractive')){Check ($callbackTestState.NativeCalls -eq 0)}
        if($mode -ceq 'commit-failure') {
            $evidence=@(Get-ChildItem $fixture.Layout.Tmp -Directory -Filter science-transaction-*)
            Check ($evidence.Count -eq 1)
            foreach($name in @('approved-lock.json','locked-preflight.json')){Check (Test-Path -LiteralPath (Join-Path $evidence[0].FullName $name)) 'Transaction diagnostic evidence missing'}
        }
    }
}
Case 'activated-environment-blocks-real-callback-before-gtk-or-commit' {
    . $setup;$oldConda=$env:CONDA_PREFIX
    try{$env:CONDA_PREFIX=$fixture.Layout.Science;Reject {Review-Fixture $fixture} 'Deactivate Science'}finally{$env:CONDA_PREFIX=$oldConda}
    Check ($callbackTestState.CommitCalls -eq 0 -and $callbackTestState.CimCalls -eq 0)
    Check-HookRestored $fixture
}
Case 'transaction-lock-is-held-during-planning-and-released-on-error' {
    . $setup
    $saved=$script:ScienceRelease
    $script:ScienceRelease=$saved|ConvertTo-Json -Depth 32|ConvertFrom-Json
    $script:ScienceRelease.MicromambaSha256=Get-ScienceFileSha256 $fixture.Layout.Micromamba
    $lockState=@{Held=$false}
    function Invoke-ScienceMambaJson {
        $handle=$null
        try{$handle=[IO.File]::Open((Join-Path $fixture.Layout.Root '.science-update.lock'),'Open','ReadWrite','None')}catch [IO.IOException]{$lockState.Held=$true}finally{if($handle){$handle.Dispose()}}
        throw 'TEST: planning stopped'
    }
    try{Reject {Invoke-ScienceEnvironmentSync $fixture.Layout @('science-root')} 'planning stopped'}finally{$script:ScienceRelease=$saved}
    Check $lockState.Held 'Transaction lock was not held'
    $handle=[IO.File]::Open((Join-Path $fixture.Layout.Root '.science-update.lock'),'Open','ReadWrite','None');$handle.Dispose()
    Check ($callbackTestState.NativeCalls -eq 0)
}
Case 'wrong-science-prefix-is-rejected-before-native-work' {
    . $setup;$fixture.Layout.Science=Join-Path $work 'unrelated'
    Reject {Invoke-ScienceEnvironmentSync $fixture.Layout @('science-root')} 'Unexpected Science prefix'
    Check ($callbackTestState.NativeCalls -eq 0)
}
Case 'approved-identity-mismatch-stops-before-staging' {
    . $setup
    $names=@(Get-ScienceRemovalCandidates $fixture.Before $fixture.Plan $fixture.Layout.Science)
    $lock=New-ScienceApprovedLock $fixture.Before $fixture.Plan $fixture.Layout.Science (Get-ScienceFileSha256 $fixture.Config) (Get-ScienceFileSha256 $fixture.Layout.Micromamba) @() $names
    Reject {Invoke-ScienceLockedTransaction $fixture.Layout $lock (Join-Path $fixture.Layout.Tmp 'unused') $fixture.Config ('0'*64)} 'Approved identity changed'
    Check ($callbackTestState.NativeCalls -eq 0)
}
$report=[ordered]@{powershell=$PSVersionTable.PSVersion.ToString();tests=$results.ToArray();failed=@($results|Where-Object {-not $_.pass}).Count;real_native_package_transactions=0;work=$work}
[IO.File]::WriteAllText((Join-Path $work 'results.json'),($report|ConvertTo-Json -Depth 8))
Write-Host ('RESULT tests='+$results.Count+' failed='+$report.failed+' evidence='+$work)
if($report.failed){exit 1}
}
