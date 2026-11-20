[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath())

$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'windows/science-release.ps1')
. (Join-Path $repo 'windows/science-update.ps1')

$work=Join-Path $TempRoot ('science-remove-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)

function Check($Condition,[string]$Message){if(-not $Condition){throw $Message}}

try {
    $scriptPath=Join-Path $repo 'windows/04-remove-science.ps1'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    Check (-not $errors.Count) 'The removal script did not parse.'
    # Run the production body as a child script with the verified helpers above.
    $entry=$ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Stop-Removal'
    } | Select-Object -First 1
    Check ($null -ne $entry) 'The removal body could not be located.'
    $testScript=Join-Path $work 'remove.ps1'
    $body=[IO.File]::ReadAllText($scriptPath).Substring($entry.Extent.StartOffset)
    [IO.File]::WriteAllText($testScript, ('param([string]$Mode)' + "`n" + $body), [Text.UTF8Encoding]::new($true))
    $fake=@'
$expected=@('env','remove','--no-rc','-r',$fixture.Layout.Root,'-p',$fixture.Layout.Science,'-y')
if(($args -join '|') -cne ($expected -join '|')){throw 'Unexpected command arguments.'}
$fixture.Calls++
if($fixture.Name -eq 'native-failure'){exit 31}
[IO.Directory]::Move($fixture.Layout.Science,$fixture.Removed)
exit 0
'@

    $prompt='Remove Science environment and its shortcuts? [y/N]'
    $passed=0
    foreach($name in 'enter','no','approved','native-failure','foreign-owner','changed-owner','in-use'){
        $root=Join-Path $work $name
        $prefix=Join-Path $root 'envs/science'
        $other=Join-Path $root 'envs/other'
        [void][IO.Directory]::CreateDirectory($prefix)
        [void][IO.Directory]::CreateDirectory($other)
        $binary=Join-Path $root 'fake-micromamba.ps1'
        $state=Join-Path $root 'installer-state.json'
        $marker=Join-Path $prefix '.science-environment-owner'
        $config=Join-Path $root 'science-release.json'
        $sentinel=Join-Path $other 'keep.txt'
        [IO.File]::WriteAllText($config,'package requests')
        [IO.File]::WriteAllText($sentinel,'other environment')
        $layout=[pscustomobject]@{Mode='Home';Root=$root;Science=$prefix;Pkgs=(Join-Path $root 'pkgs');
            Micromamba=$binary;State=$state;Sid='test-user'}
        $id='a'*32
        Write-ScienceTransactionJson $state @{root=$root;user_sid=$layout.Sid;layout_mode=$layout.Mode;
            micromamba=$binary;science_owner_id=$id}
        $ownership=@{prefix=$prefix;sid=$layout.Sid;id=$id}
        if($name -eq 'foreign-owner'){$ownership.sid='other-user'}
        Write-ScienceTransactionJson $marker $ownership
        $before=Get-ScienceFileSha256 $state
        $fixture=@{Layout=$layout;Name=$name;Calls=0;Shortcuts=0;Usage=0;
            Removed=(Join-Path $root 'moved-science')}
        [IO.File]::WriteAllText($binary,$fake)
        $ScienceRelease.MicromambaSha256=Get-ScienceFileSha256 $binary

        function Resolve-ExistingScienceLayout {param($Mode,[switch]$Interactive);return $fixture.Layout}
        function Test-ScienceInteractiveConfiguration {return $true}
        function Show-OtherInstallationSummary {Write-Host 'Other fixture environments'}
        function Assert-ScienceNotInUse {
            $fixture.Usage++
            if($fixture.Name -eq 'in-use' -and $fixture.Usage -eq 2){throw 'The Science environment is in use.'}
        }
        function Read-Host {
            param([string]$Prompt)
            Write-Host $Prompt
            if($fixture.Name -eq 'changed-owner'){
                Write-ScienceTransactionJson $marker @{prefix=$fixture.Layout.Science;sid='other-user';id=$id}
            }
            switch($fixture.Name){'enter'{return ''} 'no'{return 'N'} default{return 'Y'}}
        }
        function Remove-ScientificPythonSpyderLauncher {param($Layout);$fixture.Shortcuts++}

        $output=& $testScript -Mode Home 6>&1
        $code=$LASTEXITCODE
        $lines=@($output | ForEach-Object {$_.ToString()})
        $messages=$lines -join "`n"
        if($name -ne 'foreign-owner'){
            $position=[Array]::IndexOf($lines,$prompt)
            Check ($position -gt 0 -and $lines[$position-1] -ceq "Selected environment: $prefix") "${name}: target did not immediately precede confirmation. $messages"
        }
        if($name -in 'enter','no'){
            Check ($code -eq 0 -and $lines[-1] -ceq 'Science removal cancelled.') "${name}: incorrect cancellation result."
            Check ($messages -notmatch 'PENDING|ERROR|error code') "${name}: cancellation displayed an error."
            Check (-not (Test-Path -LiteralPath (Join-Path $root '.science-update.lock'))) "${name}: cancellation created a lock file."
        }elseif($name -eq 'approved'){
            Check ($code -eq 0 -and $messages -match 'The science environment was removed') "Approved removal failed: $messages"
            Check ($fixture.Calls -eq 1 -and $fixture.Shortcuts -eq 1 -and $fixture.Usage -eq 2) 'The approved path did not pass through its normal checks and operations.'
            Check ((Read-ScienceJson $state).finalization_stage -ceq 'removed') 'The approved operation did not finalize.'
        }else{
            $reason=switch($name){
                'native-failure' {'exit 31'}
                'in-use' {'in use'}
                default {'ownership evidence'}
            }
            Check ($code -eq 1 -and $messages -match "ERROR: .*$reason") "${name}: failure was not reported: $messages"
        }
        if($name -ne 'approved'){
            $calls=if($name -eq 'native-failure'){1}else{0}
            Check ($fixture.Calls -eq $calls -and $fixture.Shortcuts -eq 0 -and [IO.Directory]::Exists($prefix)) "${name}: removal crossed the expected boundary."
            Check ((Get-ScienceFileSha256 $state) -ceq $before) "${name}: installer state changed."
        }
        Check (([IO.File]::ReadAllText($config) -ceq 'package requests') -and
            ([IO.File]::ReadAllText($sentinel) -ceq 'other environment')) "${name}: other data changed."
        $passed++
        Write-Host "PASS $name"
    }
    Write-Host "RESULT tests=$passed failed=0"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
