[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$source=Join-Path $root 'windows'
$work=Join-Path ([IO.Path]::GetFullPath($TempRoot)) ('launcher-repair-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$env:TEMP=$work;$env:TMP=$work
. (Join-Path $source 'science-launcher-common.ps1')
. (Join-Path $source 'science-update.ps1')
$powershell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$results=New-Object Collections.Generic.List[object]
function Check {param([bool]$Value,[string]$Message='Assertion failed');if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body);try{& $Body;$results.Add(@{name=$Name;pass=$true});Write-Host "PASS $Name"}catch{$results.Add(@{name=$Name;pass=$false;error=$_.Exception.Message;stack=$_.ScriptStackTrace});Write-Host "FAIL ${Name}: $($_.Exception.Message)"}}
function Put-Text {param([string]$Path,[string]$Text);[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($true)))}
function Put-Json {param([string]$Path,$Value);Put-Text $Path ($Value|ConvertTo-Json -Depth 64)}
function Digest {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Literal {param([string]$Text);return "'"+$Text.Replace("'","''")+"'"}
function Function-Text {param([string]$File,[string]$Name)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($File,[ref]$tokens,[ref]$errors)
    Check (-not $errors.Count)
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true)
    Check ($null -ne $node);return $node.Extent.Text
}
$launcherFunction=Function-Text (Join-Path $source '02-install-science.ps1') 'Install-SpyderLauncher'
$hashFunction=Function-Text (Join-Path $source 'science-release.ps1') 'Get-ScienceFileSha256'
$specFunction=Function-Text (Join-Path $source 'science-release.ps1') 'Get-SciencePackageSpecs'
foreach($mode in @('approved','repeat','check-only','reject','default-no','noninteractive','wrong-identities','wrong-config','wrong-executable','busy','changed-after-approval','foreign-shortcut','legacy-context','direct-default')) {
    Case ('standalone-launcher-'+$mode) {
        # Execute the unmodified repair entry point from a real .ps1 file.
        # Only OS/user-location/interaction boundaries are replaced in fixture
        # bootstrap files. Verification, identity comparisons, installer function,
        # Copy-Item, command generation and WScript shortcut operations are real.
        $dir=Join-Path $work ('fixture with spaces '+[Guid]::NewGuid().ToString('N'))
        $bundle=Join-Path $dir 'bundle';$target=Join-Path $dir 'target';$bin=Join-Path $dir 'bin';$desktop=Join-Path $dir 'desktop'
        foreach($p in @($bundle,$target,$bin,$desktop,(Join-Path $bundle 'shared'),(Join-Path $target 'tmp'),(Join-Path $target 'envs/science/conda-meta'),(Join-Path $target 'envs/science/Scripts'))){[void][IO.Directory]::CreateDirectory($p)}
        $manifest=[IO.File]::ReadAllLines((Join-Path $source 'SHA256SUMS.txt'))
        foreach($line in $manifest){
            $name=($line -split '  ',2)[1]
            $from=if($name.StartsWith('shared/')){Join-Path (Join-Path $root 'shared') $name.Substring(7)}else{Join-Path $source $name}
            $to=Join-Path $bundle $name;[void][IO.Directory]::CreateDirectory((Split-Path $to -Parent));Copy-Item -LiteralPath $from -Destination $to
        }
        $layout=[pscustomobject]@{Root=$target;Bin=$bin;Science=(Join-Path $target 'envs/science');Tmp=(Join-Path $target 'tmp');Micromamba=(Join-Path $target 'not-executable.txt')}
        Put-Text $layout.Micromamba 'Inert identity sentinel. Never execute.'
        Put-Text (Join-Path $layout.Science 'python.exe') 'Inert python sentinel. Never execute.'
        Put-Text (Join-Path $layout.Science 'Scripts/spyder.exe') 'Inert Spyder sentinel. Never execute.'
        $records=@()
        foreach($entry in @(@('python','3.14.0','0'),@('python_abi','3.14','0_cp314'),@('spyder','6.1.8','0'),@('opencv','5.1.0','qt6_fixture'),@('ffmpeg','9.0.2','gpl_fixture'),@('apache-arrow-proc','23.0.0','cpu'))){
            $records += [pscustomobject]@{name=$entry[0];version=$entry[1];build=$entry[2];subdir='win-64';sha256=('a'*64)}
        }
        for($i=$records.Count;$i -lt 490;$i++){$records += [pscustomobject]@{name=('fixture-dep-'+$i);version='1.0';build='0';subdir='noarch';sha256=('b'*64)}}
        foreach($r in $records){Put-Json (Join-Path $layout.Science ('conda-meta/'+$r.name+'.json')) $r}
        $config=Join-Path $dir 'config.json';Put-Json $config @{fixture='unchanged user configuration'}
        $transaction=Join-Path $layout.Tmp ('science-transaction-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($transaction)
        $lock=Join-Path $transaction 'approved-lock.json';Put-Json $lock @{prefix=$layout.Science;config_sha256=(Digest $config);executable_sha256=(Digest $layout.Micromamba);after=$records}
        $paths=[pscustomobject]@{Script=(Join-Path $target 'start-spyder.ps1');Command=(Join-Path $bin 'science-spyder.cmd');Shortcut=(Join-Path $desktop 'Scientific Python science - Spyder.lnk')}
        $state=Join-Path $dir 'test-state.json';Put-Json $state @{Layout=$layout;Paths=$paths;Config=$config;Mode=$mode;Prompts=(Join-Path $dir 'prompts.txt');Native=(Join-Path $dir 'native-called.txt')}
        # Actual production modules supply verification and safety functions.
        # Select fixture paths rather than the computer's real user roots.
        Put-Text (Join-Path $bundle 'science-common.ps1') ('. '+(Literal (Join-Path $source 'science-common.ps1')))
        Put-Text (Join-Path $bundle 'science-release.ps1') (('. '+(Literal (Join-Path $source 'science-config.ps1')))+"`r`n"+$hashFunction+"`r`n"+$specFunction+"`r`n"+'$script:ScienceRelease=[pscustomobject]@{Channels=@("conda-forge");ScientificPackages=@("python","python_abi","spyder","opencv","ffmpeg","apache-arrow-proc");OpenCV="5.1.0";FFmpeg="9.0.0"}')
        $boundaries=@'
$script:RepairFixture=Read-ScienceJson __STATE__
function Get-ScienceLayoutByMode {param($Mode);return $script:RepairFixture.Layout}
function Get-ScientificPythonSpyderLauncherPaths {param($Layout);return $script:RepairFixture.Paths}
function Get-ScienceConfigurationPath {return $script:RepairFixture.Config}
function Test-ScienceInteractiveConfiguration {return ($script:RepairFixture.Mode -cne 'noninteractive')}
function Get-CimInstance {param($ClassName,$ErrorAction);if($script:RepairFixture.Mode -ceq 'busy'){return [pscustomobject]@{ExecutablePath=(Join-Path $script:RepairFixture.Layout.Science 'python.exe')}};return @()}
function Read-Host {param([string]$Prompt)
    [IO.File]::AppendAllText($script:RepairFixture.Prompts,$Prompt+"`n")
    if($script:RepairFixture.Mode -ceq 'reject'){return 'no'}
    if($script:RepairFixture.Mode -ceq 'default-no'){return ''}
    if($script:RepairFixture.Mode -ceq 'changed-after-approval'){[IO.File]::AppendAllText($script:RepairFixture.Config,' ')}
    return 'yes'
}
function Invoke-ScienceNative {[IO.File]::WriteAllText($script:RepairFixture.Native,'CALLED');throw 'A launcher repair must never invoke a native package transaction.'}
'@
        Put-Text (Join-Path $bundle 'science-update.ps1') (('. '+(Literal (Join-Path $source 'science-update.ps1')))+"`r`n"+$boundaries.Replace('__STATE__',(Literal $state)))
        if($mode -ceq 'legacy-context'){
            $repair=Join-Path $bundle '09-repair-launchers.ps1'
            Put-Text $repair ([IO.File]::ReadAllText($repair).Replace('Install-SpyderLauncher -Layout $layout -SourceDirectory $PSScriptRoot','Install-SpyderLauncher -Layout $layout'))
        }
        $rows=@();foreach($line in $manifest){$name=($line -split '  ',2)[1];$rows += (Digest (Join-Path $bundle $name))+'  '+$name}
        Put-Text (Join-Path $bundle 'SHA256SUMS.txt') ($rows -join "`r`n")
        if($mode -ceq 'wrong-identities'){Put-Json (Join-Path $layout.Science 'conda-meta/python.json') @{name='python';version='3.14.1';build='0';subdir='win-64';sha256=('c'*64)}}
        if($mode -ceq 'wrong-config'){[IO.File]::AppendAllText($config,' ')}
        if($mode -ceq 'wrong-executable'){[IO.File]::AppendAllText($layout.Micromamba,' ')}
        if($mode -ceq 'foreign-shortcut'){
            $shell=New-Object -ComObject WScript.Shell;$foreign=$shell.CreateShortcut($paths.Shortcut);$foreign.TargetPath=$powershell;$foreign.Arguments='-NoProfile';$foreign.Save();$foreignHash=Digest $paths.Shortcut
        }
        $protected=@{};foreach($p in @((Get-ChildItem $layout.Science -Recurse -File).FullName)+@($config,$lock,$layout.Micromamba)){$protected[$p]=Digest $p}
        $entry=Join-Path $bundle '09-repair-launchers.ps1'
        if($mode -ceq 'direct-default'){
            # Normal installer-defined function keeps its script context and
            # must continue to work without specifying the new parameter.
            $entry=Join-Path $bundle 'direct-definition.ps1'
            Put-Text $entry ('. (Join-Path $PSScriptRoot "science-integrity.ps1"); . (Join-Path $PSScriptRoot "science-common.ps1"); . (Join-Path $PSScriptRoot "science-release.ps1"); . (Join-Path $PSScriptRoot "science-update.ps1")'+"`r`n"+'function Stop-Install {param($Message);throw $Message}'+"`r`n"+$launcherFunction+"`r`n"+'Install-SpyderLauncher -Layout $script:RepairFixture.Layout')
        }
        $runs=if($mode -ceq 'repeat'){2}else{1}
        for($run=0;$run -lt $runs;$run++){
            $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$entry)
            if($mode -cne 'direct-default'){$arguments += @('-Mode','Home','-TransactionDirectory',$transaction);if($mode -cne 'check-only'){$arguments += '-Apply'}}
            $native=Invoke-ScienceNative $powershell $arguments @{TEMP=$work;TMP=$work}
            $output=$native.Stdout+"`n"+$native.Stderr;$exitCode=$native.ExitCode
            Put-Text (Join-Path $dir ('output-'+$run+'.txt')) $output
        }
        $expected=switch($mode){'noninteractive'{'interactive console'};'wrong-identities'{'identities do not match'};'wrong-config'{'Configuration differs'};'wrong-executable'{'Micromamba identity differs'};'busy'{'Close Science'};'changed-after-approval'{'Repair inputs changed'};'foreign-shortcut'{'different shortcut'};'legacy-context'{'empty string'}}
        if($expected){Check ($exitCode -ne 0 -and $output -match $expected) ('Wrong failure: '+$exitCode+' '+$output)}else{Check ($exitCode -eq 0) ('Unexpected error: '+$output)}
        $success=$mode -In @('approved','repeat','direct-default')
        if($success){
            foreach($p in @($paths.Script,$paths.Command,$paths.Shortcut,(Join-Path $layout.Root 'science-launcher-common.ps1'))){Check ([IO.File]::Exists($p)) ('Missing launcher: '+$p)}
            Check ((Digest $paths.Script) -ceq (Digest (Join-Path $source 'spyder-launcher.ps1')))
            Check ([IO.File]::ReadAllText($paths.Command).Contains($paths.Script))
            $shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($paths.Shortcut)
            Check ($shortcut.TargetPath -ieq $powershell -and $shortcut.Arguments.Contains($paths.Script))
        } elseif($mode -cne 'foreign-shortcut'){
            Check (-not [IO.File]::Exists($paths.Script) -and -not [IO.File]::Exists($paths.Command) -and -not [IO.File]::Exists($paths.Shortcut)) 'Unexpected launcher write'
        } else {Check ((Digest $paths.Shortcut) -ceq $foreignHash) 'Foreign shortcut overwritten'}
        foreach($p in $protected.Keys){if($mode -ceq 'changed-after-approval' -and $p -ceq $config){continue};Check ((Digest $p) -ceq $protected[$p]) ('Protected fixture changed: '+$p)}
        Check (-not [IO.File]::Exists((Join-Path $dir 'native-called.txt'))) 'Native transaction invoked'
        $prompts=Join-Path $dir 'prompts.txt'
        if($mode -In @('check-only','noninteractive','wrong-identities','wrong-config','wrong-executable','busy')){Check (-not [IO.File]::Exists($prompts)) 'Unexpected approval prompt'}
        if($mode -In @('approved','repeat','reject','default-no','legacy-context')){Check ([IO.File]::ReadAllText($prompts).Contains('[y/N]'))}
        $stream=$null;try{$stream=[IO.File]::Open((Join-Path $layout.Root '.science-update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}finally{if($stream){$stream.Dispose()}}
    }
}
$report=[ordered]@{powershell=$PSVersionTable.PSVersion.ToString();tests=$results.ToArray();failed=@($results|Where-Object {-not $_.pass}).Count;real_micromamba_transactions=0;all_targets_under=$work;work=$work}
Put-Json (Join-Path $work 'results.json') $report
Write-Host ('RESULT tests='+$results.Count+' failed='+$report.failed+' evidence='+$work)
if($report.failed){exit 1}
