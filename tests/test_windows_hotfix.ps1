[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath(),[switch]$ConsoleTests)
$ErrorActionPreference='Stop'
$TempRoot=[IO.Path]::GetFullPath($TempRoot)
$root=Split-Path $PSScriptRoot
$work=Join-Path $TempRoot ('windows-hotfix-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$env:TEMP=$work;$env:TMP=$work
. (Join-Path $root 'windows/science-release.ps1')
. (Join-Path $root 'windows/science-launcher-common.ps1')
. (Join-Path $root 'windows/science-update.ps1')
$results=New-Object Collections.Generic.List[object]
function Check {param([bool]$Condition,[string]$Message='Assertion failed');if(-not $Condition){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body);try{& $Body;$results.Add(@{name=$Name;pass=$true});Write-Host "PASS $Name"}catch{$results.Add(@{name=$Name;pass=$false;error=$_.Exception.Message});Write-Host "FAIL ${Name}: $($_.Exception.Message)"}}
function Load-Function {param([string]$Path,[string]$Name)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Check (-not $errors.Count) 'PowerShell parse failure'
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true)
    return [scriptblock]::Create($node.Extent.Text)
}
function Fixture-Config {
    $value=Get-ScienceDefaultConfiguration
    $seven=@('shap','pywavelets','optuna','plotly','hypothesis','polars','xgboost')
    $value.ScientificPackages=@($value.ScientificPackages|Where-Object {$seven -cnotcontains (Get-ScienceSpecName $_)}|ForEach-Object {if($_ -ceq 'numpy'){'numpy>=2,<3'}else{$_}})+@('pingouin')
    $value.Channels=@('conda-forge','my-lab')
    return $value
}
function Write-Config {param([string]$Path,$Value);[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($false)))}
Case 'production-solve-arguments-remain-separate-strings' {
    $Layout=[pscustomobject]@{Root=$work;Science=(Join-Path $work 'envs/science');Pkgs=$work;Tmp=$work;Micromamba='mock-only'}
    $effective=Fixture-Config;$Packages=$effective.ScientificPackages;$floors=@{opencv='5.0.0';ffmpeg='9.0.2'};$verb='update';$isInstalled=$true
    $body=Load-Function (Join-Path $root 'windows/science-update.ps1') 'Invoke-ScienceEnvironmentSync'
    $assignments=$body.Ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$arguments'},$true)
    Check ($assignments.Count -eq 3) 'Missing actual production argument statements'
    foreach($statement in $assignments){. ([scriptblock]::Create($statement.Extent.Text))}
    $capture=@{Calls=0}
    function Invoke-ScienceNative {param([string]$Executable,[string[]]$Arguments,[hashtable]$Environment)
        $capture.Calls++;$capture.Arguments=$Arguments
        return @{ExitCode=0;Stdout='{"success":true}';Stderr=''}
    }
    $null=Invoke-ScienceMambaJson $Layout $arguments
    Check ($capture.Calls -eq 1)
    $nativeArgs=$capture.Arguments
    Check (($nativeArgs[5..11] -join '|') -ceq '--no-rc|--override-channels|--strict-channel-priority|-c|conda-forge|-c|my-lab')
    Check (@($arguments|Where-Object {$_ -isnot [string]}).Count -eq 0) 'Nested argument array'
    Check ($nativeArgs -ccontains '--dry-run');Check ($nativeArgs -ccontains '--all')
    foreach($spec in $Packages){Check ($nativeArgs -ccontains $spec) 'Constraint changed in binding'}
    Check ($nativeArgs -ccontains 'ffmpeg>=9.0.2')
}
foreach($answer in @('','no','yes')) {
    Case ('configuration-approval-'+$(if($answer){$answer}else{'default-no'})) {
        $path=Join-Path $work ('config-'+[Guid]::NewGuid().ToString('N')+'.json');$value=Fixture-Config;Write-Config $path $value
        $hash=(Get-FileHash $path).Hash;$context=@{Calls=0;Prompt=''}
        $review={param($prompt);$context.Calls++;$context.Prompt=$prompt;return $answer}.GetNewClosure()
        $actual=Update-ScienceReleasePackages -Path $path -Interactive $true -Reviewer $review
        Check ($context.Calls -eq 1);Check ($context.Prompt.EndsWith('[y/N]'))
        Check (($actual.Channels -join '|') -ceq ($value.Channels -join '|'))
        Check (($actual.ScientificPackages[0..35] -join '|') -ceq ($value.ScientificPackages -join '|'))
        if($answer -ceq 'yes') {
            Check ($actual.ScientificPackages.Count -eq 43)
            Check (($actual.ScientificPackages[36..42] -join '|') -ceq 'shap|pywavelets|optuna|plotly|hypothesis|polars|xgboost')
            $null=Update-ScienceReleasePackages -Path $path -Interactive $true -Reviewer {throw 'Unexpected repeated prompt'}
        }else{Check ((Get-FileHash $path).Hash -ceq $hash)}
    }
}
Case 'noninteractive-configuration-does-not-approve-or-prompt' {
    $path=Join-Path $work 'noninteractive.json';Write-Config $path (Fixture-Config);$hash=(Get-FileHash $path).Hash
    $null=Update-ScienceReleasePackages -Path $path -Interactive $false -Reviewer {throw 'Noninteractive prompt'}
    Check ((Get-FileHash $path).Hash -ceq $hash)
}
Case 'package-transaction-still-requires-separate-default-no-approval' {
    function Test-ScienceInteractiveConfiguration {return $true}
    $context=@{Calls=0;CommitCalls=0;Prompt=''}
    function New-ScienceApprovedLock {return [pscustomobject]@{prefix=$work;approved=[pscustomobject]@{actions=[pscustomobject]@{LINK=@();UNLINK=@()}}}}
    function Get-ScienceRecords {return @{}}
    function Get-ScienceRemovalCandidates {return}
    function Get-ScienceFileSha256 {return ('0'*64)}
    function Read-Host {param([string]$Prompt);$context.Calls++;$context.Prompt=$Prompt;return ''}
    function Invoke-ScienceLockedTransaction {$context.CommitCalls++;throw 'Forbidden commit'}
    $caught=$null
    try{Invoke-ScienceReviewedTransaction ([pscustomobject]@{Tmp=$work}) @{} @{} 'mock-config'}catch{$caught=$_}
    Check ($null -ne $caught -and $caught.Exception.Message -match 'Transaction cancelled')
    Check ($context.Calls -eq 1 -and $context.CommitCalls -eq 0)
    Check ($context.Prompt -ceq 'Apply exactly this transaction? [y/N]')
}
foreach($kind in @('exit109','unsatisfiable','invalid-json','unsuccessful-json')) {
    Case ('solver-diagnostics-'+$kind) {
        $testDir=Join-Path $work $kind;[void][IO.Directory]::CreateDirectory($testDir)
        $layout=[pscustomobject]@{Root=$work;Science=$work;Pkgs=$work;Tmp=$testDir;Micromamba='mock-only'}
        $exit=if($kind -ceq 'exit109'){109}elseif($kind -ceq 'unsatisfiable'){1}else{0}
        $stdout=if($kind -ceq 'invalid-json'){'not-json'}else{'{"success":false,"message":"numpy conflicts with python; https:\/\/url-user:url-pass@example.test/t/path-token/channel?access_token=query-token"}'}
        $context=@{Exit=$exit;Stdout=$stdout;Calls=0}
        function Invoke-ScienceNative {param($Executable,[string[]]$Arguments,$Environment);$context.Calls++;return @{ExitCode=$context.Exit;Stdout=$context.Stdout;Stderr='Authorization: Bearer header-token password=json-pass separate-secret path-token query-token url-user url-pass env-secret inline secret phrase test-api-key {"password":"quoted secret phrase"}'}}
        $oldSecret=$env:SCIENCE_TEST_TOKEN;$env:SCIENCE_TEST_TOKEN='env-secret'
        try {
            $caught=$null
            try{$null=Invoke-ScienceMambaJson $layout @('update','--dry-run','--token','separate-secret','--password=json-pass','--password=inline secret phrase','--api-key=test-api-key','-c','https://url-user:url-pass@example.test/t/path-token/channel?access_token=query-token')}catch{$caught=$_}
            Check ($null -ne $caught) 'Failure swallowed';Check ($context.Calls -eq 1) 'Unexpected retry'
            $directories=@(Get-ChildItem $testDir -Directory);Check ($directories.Count -eq 1)
            Check ($caught.Exception.Message.Contains($directories[0].FullName)) 'Diagnostic path missing'
            $summary=Get-Content (Join-Path $directories[0].FullName 'failure.json') -Raw|ConvertFrom-Json
            Check ($summary.exit_code -eq $exit)
            $all=(@(Get-ChildItem $directories[0].FullName -File|ForEach-Object {[IO.File]::ReadAllText($_.FullName)}) -join "`n")
            foreach($secret in @('separate-secret','header-token','json-pass','path-token','query-token','url-user','url-pass','env-secret','inline secret phrase','quoted secret phrase','test-api-key')){Check (-not $all.Contains($secret)) ('Credential leaked: '+$secret)}
            Check (Test-Path (Join-Path $directories[0].FullName 'stdout.txt'));Check (Test-Path (Join-Path $directories[0].FullName 'stderr.txt'))
            if($kind -cne 'invalid-json'){Check ($all.Contains('numpy conflicts with python')) 'Solver error lost'}
        }finally{$env:SCIENCE_TEST_TOKEN=$oldSecret}
    }
}
if($ConsoleTests) {
    . (Load-Function (Join-Path $root 'windows/00-menu.ps1') 'Invoke-Step')
    $BaseDir=$work
    $probe=Join-Path $work 'probe.ps1'
    $configSource=(Join-Path $root 'windows/science-config.ps1').Replace("'","''")
    $code=@'
param([string]$Output,[int]$Code=0,[switch]$Fail)
. '__CONFIG__'
$value=@{interactive=(Test-ScienceInteractiveConfiguration);input_redirected=[Console]::IsInputRedirected;output_redirected=[Console]::IsOutputRedirected}
[IO.File]::WriteAllText($Output,($value|ConvertTo-Json))
Write-Host 'CHILD-CONSOLE-OUTPUT'
if($Fail){throw 'Expected child error'}
exit $Code
'@
    [IO.File]::WriteAllText($probe,$code.Replace('__CONFIG__',$configSource))
    Case 'actual-menu-child-inherits-console-even-when-return-is-captured' {
        Check (Test-ScienceInteractiveConfiguration) 'Run -ConsoleTests inside a real interactive console'
        $evidence=Join-Path $work 'console.json'
        $rc=Invoke-Step 'probe.ps1' "-Output '$evidence'"
        $value=Get-Content $evidence -Raw|ConvertFrom-Json
        Check ($rc -is [int] -and $rc -eq 0) 'Console output polluted return code'
        Check ($value.interactive -and -not $value.output_redirected -and -not $value.input_redirected)
    }
    Case 'menu-child-exit-code-and-exception-propagation' {
        $evidence=Join-Path $work 'console-error.json'
        $rc=Invoke-Step 'probe.ps1' "-Output '$evidence' -Code 7";Check ($rc -eq 7)
        $rc=Invoke-Step 'probe.ps1' "-Output '$evidence' -Fail";Check ($rc -eq 1)
    }
    Case 'menu-propagates-noninteractive-parent' {
        function Test-ScienceInteractiveConfiguration {return $false}
        $evidence=Join-Path $work 'console-noninteractive.json'
        $rc=Invoke-Step 'probe.ps1' "-Output '$evidence'";Check ($rc -eq 0)
        $value=Get-Content $evidence -Raw|ConvertFrom-Json;Check (-not $value.interactive)
    }
}
$report=[ordered]@{powershell=$PSVersionTable.PSVersion.ToString();tests=$results.ToArray();failed=@($results|Where-Object {-not $_.pass}).Count;work=$work}
[IO.File]::WriteAllText((Join-Path $work 'results.json'),($report|ConvertTo-Json -Depth 8))
Write-Host ('RESULT tests='+$results.Count+' failed='+$report.failed+' evidence='+$work)
if($report.failed){exit 1}
