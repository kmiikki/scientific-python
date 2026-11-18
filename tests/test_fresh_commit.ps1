[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$work=Join-Path ([IO.Path]::GetFullPath($TempRoot)) ('fresh-commit-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$env:TEMP=$work;$env:TMP=$work
. (Join-Path $root 'windows/science-release.ps1')
. (Join-Path $root 'windows/science-launcher-common.ps1')
. (Join-Path $root 'windows/science-update.ps1')
$results=New-Object Collections.Generic.List[object]
function Check {param([bool]$Value,[string]$Message='Assertion failed');if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body);try{& $Body;$results.Add(@{name=$Name;pass=$true});Write-Host "PASS $Name"}catch{$results.Add(@{name=$Name;pass=$false;error=$_.Exception.Message;stack=$_.ScriptStackTrace});Write-Host "FAIL ${Name}: $($_.Exception.Message)"}}
function Put-Json {param([string]$Path,$Value);[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 64),(New-Object Text.UTF8Encoding($false)))}
# Reuse the inert archive/metadata fixture without running its test suite.
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test_callback_scope.ps1'),[ref]$tokens,[ref]$errors)
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Fixture'},$true)
. ([scriptblock]::Create($node.Extent.Text))
$realNative=(Get-Command Invoke-ScienceNative).ScriptBlock
$powershell=(Get-Process -Id $PID).Path
foreach($exitCode in @(0,7)) {
    Case ('real-process-exit-'+$exitCode+'-is-independent-of-json-success') {
        $code='[Console]::Out.WriteLine(''{"success":true}'');[Console]::Error.WriteLine(''warning fixture'');exit '+$exitCode
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $result=& $realNative $powershell @('-NoLogo','-NoProfile','-EncodedCommand',$encoded) @{TEMP=$work;TMP=$work}
        Check ($result.ExitCode -eq $exitCode)
        Check (($result.Stdout|ConvertFrom-Json).success)
        Check ($result.Stderr.Contains('warning fixture'))
    }
}
foreach($mode in @('clean','postlink-noise','nonzero-success','invalid-json','multiple-json','trailing-noise','wrong-prefix','wrong-link','wrong-unlink','installed-mismatch')) {
    Case ('fresh-create-real-executor-'+$mode) {
        $fixture=Fixture
        $link=@($fixture.Before.Values)
        foreach($p in @(Get-ChildItem -LiteralPath (Join-Path $fixture.Layout.Science 'conda-meta') -Filter '*.json' -File)){Remove-Item -LiteralPath $p.FullName}
        Remove-Item -LiteralPath $fixture.Hook -Force
        $fixture.Before=@{}
        $fixture.Plan=[pscustomobject]@{success=$true;prefix=$fixture.Layout.Science;actions=[pscustomobject]@{LINK=$link;UNLINK=@()}}
        $freshTest=@{Calls=0;Commit=0;Arguments=$null}
        function Get-ScienceConfigurationPath {return $fixture.Config}
        function Test-ScienceInteractiveConfiguration {return $true}
        function Read-Host {return 'yes'}
        function Get-CimInstance {return @()}
        function Invoke-ScienceNative {param([string]$Executable,[string[]]$Arguments,[hashtable]$Environment)
            $freshTest.Calls++
            Check ($Arguments[0] -ceq 'create') 'Fresh install did not use the create path'
            if($Arguments -ccontains '--download-only') {
                $prefix=$Arguments[[Array]::IndexOf($Arguments,'-p')+1]
                return @{ExitCode=0;Stdout=([pscustomobject]@{success=$true;prefix=$prefix;actions=[pscustomobject]@{LINK=$link}}|ConvertTo-Json -Depth 64);Stderr=''}
            }
            if($Arguments -ccontains '--dry-run'){return @{ExitCode=0;Stdout=($fixture.Plan|ConvertTo-Json -Depth 64);Stderr=''}}
            $freshTest.Commit++;$freshTest.Arguments=$Arguments
            foreach($record in $link){Put-Json (Join-Path $fixture.Layout.Science ('conda-meta/'+$record.name+'.json')) $record}
            $reply=$fixture.Plan|ConvertTo-Json -Depth 64|ConvertFrom-Json
            switch($mode) {
                wrong-prefix {$reply.prefix=Join-Path $work 'wrong-prefix'}
                wrong-link {$reply.actions.LINK[0].sha256='b'*64}
                wrong-unlink {$reply.actions.UNLINK=@($link[0])}
                installed-mismatch {Remove-Item -LiteralPath (Join-Path $fixture.Layout.Science ('conda-meta/'+$link[0].name+'.json'))}
            }
            $text=$reply|ConvertTo-Json -Depth 64
            switch($mode) {
                postlink-noise {$text="        1 file(s) moved.`r`n"+$text}
                invalid-json {$text='not-json'}
                multiple-json {$text='{"success":false}'+"`n"+$text}
                trailing-noise {$text+="`npost-link text after JSON"}
            }
            return @{ExitCode=$(if($mode -ceq 'nonzero-success'){7}else{0});Stdout=$text;Stderr='warning libmamba Library\bin\opengl32sw.dll already exists; token=fixture-secret'}
        }
        $caught=$null
        try{Invoke-ScienceReviewedTransaction $fixture.Layout $fixture.Before $fixture.Plan $fixture.Config}catch{$caught=$_}
        $directory=@(Get-ChildItem $fixture.Layout.Tmp -Directory -Filter 'science-transaction-*')[0].FullName
        $native=Join-Path $directory 'native-locked-commit'
        $result=Get-Content (Join-Path $native 'result.json') -Raw|ConvertFrom-Json
        $status=Get-Content (Join-Path $directory 'commit-verification.json') -Raw|ConvertFrom-Json
        Check ($freshTest.Commit -eq 1)
        Check ($freshTest.Arguments -ccontains '--file' -and $freshTest.Arguments -ccontains '-y')
        $logs=(@(Get-ChildItem $native -File|ForEach-Object {[IO.File]::ReadAllText($_.FullName)}) -join "`n")
        Check (-not $logs.Contains('fixture-secret')) 'Unredacted secret in native diagnostics'
        if($mode -In @('clean','postlink-noise')) {
            Check ($null -eq $caught) ('Unexpected failure: '+$caught.Exception.Message)
            Check ($status.completed -and $status.committed_plan_written -and $status.installed_identities_verified)
            Check ($status.stage -ceq 'complete')
        } else {
            Check ($null -ne $caught) 'Failure was accepted'
            Check (-not $status.completed)
            $expectedStage=if($mode -eq 'nonzero-success'){'native-exit'}elseif($mode -In @('invalid-json','multiple-json','trailing-noise')){'native-json'}elseif($mode -eq 'wrong-prefix'){'reported-prefix'}elseif($mode -In @('wrong-link','wrong-unlink')){'approved-link-unlink-identities'}elseif($mode -eq 'installed-mismatch'){'installed-identities'}else{'native-commit'}
            Check ($status.stage -ceq $expectedStage) ('Wrong failure stage: '+$status.stage)
            if($mode -ceq 'installed-mismatch'){Check $status.committed_plan_written}else{Check (-not $status.committed_plan_written)}
        }
        Check ($result.exit_code -eq $(if($mode -ceq 'nonzero-success'){7}else{0}))
        Check ($status.native_exit_code -eq $result.exit_code)
        if($mode -In @('invalid-json','multiple-json','trailing-noise')){Check ($status.stage -ceq 'native-json' -and -not $status.native_json_parsed)}
        if($mode -ceq 'nonzero-success') {
            Check ($caught.Exception.Message -match 'Locked commit failed \(exit 7\)')
            Check ($status.stage -ceq 'native-exit' -and -not $status.native_json_parsed)
            Check (($result.reason -ceq 'Locked commit') -and (Get-Content (Join-Path $native 'stdout.txt') -Raw).Contains('true'))
        }
    }
}
$report=[ordered]@{powershell=$PSVersionTable.PSVersion.ToString();tests=$results.ToArray();failed=@($results|Where-Object {-not $_.pass}).Count;real_micromamba_transactions=0;work=$work}
[IO.File]::WriteAllText((Join-Path $work 'results.json'),($report|ConvertTo-Json -Depth 8))
Write-Host ('RESULT tests='+$results.Count+' failed='+$report.failed+' evidence='+$work)
if($report.failed){exit 1}
