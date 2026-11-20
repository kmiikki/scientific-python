[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath())

$ErrorActionPreference='Stop'
$windows=Join-Path (Split-Path -Parent $PSScriptRoot) 'windows'
. (Join-Path $windows 'science-common.ps1')
. (Join-Path $windows 'science-release.ps1')
. (Join-Path $windows 'science-update.ps1')
. (Join-Path $windows 'science-root-removal.ps1')

# Keep native handle operations isolated, even when this suite is run on Windows.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
public static class ScienceRootNative {
    public static string AllowedRemoval, ChangedPath;
    public static bool Denied;
    public static int Removals;
    public static string Inspect(string path, bool testDelete) {
        return "fixture:" + File.ReadAllText(path) + (path == ChangedPath ? ":replaced" : "");
    }
    public static void Remove(string path, string expected, IDictionary<string,string> parents) {
        if (path != AllowedRemoval || Inspect(path, false) != expected)
            throw new InvalidOperationException("Unexpected deletion target: " + path);
        Removals++;
        if (Denied) throw new UnauthorizedAccessException("fixture access denied");
        File.Delete(path);
    }
}
'@

function Check($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Get-EntryAst([string]$Name){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $windows $Name),[ref]$tokens,[ref]$errors)
    Check (-not $errors.Count) "$Name did not parse."
    return $ast
}
function Write-TestScript([string]$Name,[string[]]$Statements){
    $path=Join-Path $work $Name
    [IO.File]::WriteAllLines($path,$Statements,[Text.UTF8Encoding]::new($true))
    return $path
}

$work=Join-Path $TempRoot ('science-removal-menu-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$fixture=@{Replies=$null;Routes=@();Processes=@();Shared=$false;TotalCalls=0;PlannerCalls=0;Plan=$null;Layout=$null}

function Read-Host([string]$Prompt){
    Write-Host $Prompt
    if($fixture.Case -eq 'replaced' -and $Prompt -like 'Remove this Micromamba executable*'){
        [ScienceRootNative]::ChangedPath=$fixture.Layout.Micromamba
    }
    return $fixture.Replies.Dequeue()
}
function Set-Replies([string[]]$Replies){
    $fixture.Replies=New-Object 'Collections.Generic.Queue[string]'
    foreach($answer in $Replies){$fixture.Replies.Enqueue($answer)}
}
function Clear-Host {}
function Show-State {Write-Host 'Current status'}
function Pause-Menu {}
function Invoke-Step([string]$Name,[string]$Arguments){$fixture.Routes+=,"$Name $Arguments"}
function Select-ScienceRemovalRoot([string]$ExpectedSha256,[switch]$ScienceOnly){
    if($fixture.Case -eq 'menu'){Check $ScienceOnly 'Science dispatch did not request a Science-only target.'}
    else {Check (-not $ScienceOnly) 'Executable removal should also support a directory without Science.'}
    return $fixture.Layout
}
function Test-ScienceInteractiveConfiguration {return $true}
function Get-CimInstance {param($ClassName);return $fixture.Processes}
function Get-ScienceCleanupSetting([string]$Name,[string]$Scope){
    if($fixture.Shared -and $Name -eq 'MAMBA_EXE' -and $Scope -eq 'Machine'){return $fixture.Layout.Micromamba}
}
function Get-ScienceCleanupInventory([string]$ExpectedSha256){return $fixture.Inventory}
# Match path containment for the disposable host paths used by these tests.
function Test-PathWithin([string]$Path,[string]$Base){
    $separator=[IO.Path]::DirectorySeparatorChar
    return ($Path -and $Base -and ($Path -eq $Base -or $Path.StartsWith($Base+$separator)))
}
function Get-ScienceTotalRemovalPlan($Row,$Inventory,[string]$ExpectedSha256){
    $fixture.PlannerCalls++
    Check ($Row.Root -ceq $fixture.Layout.Root) 'Total Remove passed the wrong root into the planner.'
    if($fixture.Case -eq 'unsafe'){throw 'fixture unsafe target'}
    return $fixture.Plan
}
function Invoke-ScienceTotalRemoval($Plan,[scriptblock]$Recheck){
    Check ($Plan -eq (& $Recheck)) 'Total Remove did not recheck the approved plan.'
    $fixture.TotalCalls++
    return @{Status='SUCCESS'}
}

try {
    $passed=0
    $menu=(Get-EntryAst '00-menu.ps1').EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.WhileStatementAst]
    }
    $menuScript=Write-TestScript 'menu.ps1' $menu.Extent.Text
    $fixture.Case='menu'
    $fixture.Layout=[pscustomobject]@{Mode='Safe'}
    Set-Replies @('4','5','M','6','Q')
    $messages=@(& $menuScript 6>&1 | ForEach-Object {$_.ToString()})
    Check ($LASTEXITCODE -eq 0) 'The main menu did not return normally.'
    $header='Scientific Python 0.9.2 (Windows 11)'
    Check (($messages[0..3] -join '|') -ceq (@($header,('=' * $header.Length),'','Current status') -join '|')) 'Version, separator or blank line in the main menu was incorrect.'
    foreach($line in '  5  Remove Science environment',
        '  M  Remove Micromamba installed by Scientific Python',
        '  6  Total Remove – delete selected Micromamba directory and all contents'){
        Check ($messages -ccontains $line) "Missing menu label: $line"
    }
    Check (($fixture.Routes -join '|') -ceq
        "03-remove-spyder-settings.ps1 |04-remove-science.ps1 -Mode 'Safe'|10-remove-micromamba-executable.ps1 |05-remove-micromamba.ps1 ") 'Removal menu actions did not route correctly.'
    $passed++;Write-Host 'PASS menu routing and version'

    $ScienceRelease.InstallerVersion='10.20.300'
    Set-Replies @('Q')
    $messages=@(& $menuScript 6>&1 | ForEach-Object {$_.ToString()})
    $header='Scientific Python 10.20.300 (Windows 11)'
    Check ($LASTEXITCODE -eq 0 -and
        ($messages[0..3] -join '|') -ceq (@($header,('=' * $header.Length),'','Current status') -join '|')) 'The header did not adapt to a longer version.'
    $ScienceRelease.InstallerVersion='0.9.2'
    $passed++;Write-Host 'PASS dynamic menu header'

    $headingCalls=@{'00-menu.ps1'=2;'01-prepare-windows.ps1'=1;'02-install-science.ps1'=2}
    $installerPolicy=[pscustomobject]@{InstallerVersion='10.20.300'}
    $ScienceRelease.InstallerVersion=$installerPolicy.InstallerVersion
    $heading='Scientific Python 10.20.300 (Windows 11)'
    foreach($file in $headingCalls.Keys){
        $calls=(Get-EntryAst $file).FindAll({param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Write-ScienceInstallerHeading'
        },$true)
        Check ($calls.Count -eq $headingCalls[$file]) "$file is missing the common Windows heading."
        foreach($call in $calls){
            $lines=@(& ([scriptblock]::Create($call.Extent.Text)) 6>&1 | ForEach-Object {$_.ToString()})
            Check (($lines -join '|') -ceq ($heading+'|'+('=' * $heading.Length))) "$file printed an inconsistent heading."
        }
    }
    $ScienceRelease.InstallerVersion='0.9.2'
    $passed++;Write-Host 'PASS matching headings on menu, preparation and install screens'

    $download=(Get-EntryAst '02-install-science.ps1').EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -ceq '$needDownload'
    }
    Check ($null -ne $download) 'The installer download path could not be located.'
    $downloadScript=Write-TestScript 'download.ps1' $download.Extent.Text
    $null=Write-TestScript 'science-root-removal.ps1' '# Native loader is already mocked in this process.'
    function curl.exe {
        [IO.File]::WriteAllText($tempExe,'downloaded fixture')
        if($fixture.Case -eq 'destination-appeared'){[IO.File]::WriteAllText($layout.Micromamba,'unrelated fixture')}
        $global:LASTEXITCODE=0
    }
    $needDownload=$true
    $hadExecutable=$false
    $downloadUrl='unused test URL'
    foreach($name in 'downloaded','existed-before','changed-identity','destination-appeared'){
        $fixture.Case=$name
        $root=Join-Path $work $name
        [void][IO.Directory]::CreateDirectory($root)
        $layout=[pscustomobject]@{Root=$root;Mode='Home';Sid='test-user';Micromamba=(Join-Path $root 'micromamba.exe');
            State=(Join-Path $root 'installer-state.json')}
        $tempExe=Join-Path $root 'download.tmp'
        Write-ScienceTransactionJson $layout.State @{schema_version=2;root=$root;micromamba=$layout.Micromamba;
            user_sid=$layout.Sid;layout_mode=$layout.Mode;micromamba_existed_before=($name -eq 'existed-before')}
        $ScienceRelease.MicromambaSha256=Get-ScienceTextDigest 'downloaded fixture'
        [ScienceRootNative]::ChangedPath=if($name -eq 'changed-identity'){$layout.Micromamba}else{$null}
        $failure=$null
        try {& $downloadScript} catch {$failure=$_.Exception}
        $state=Get-SciencePreparedInstallationState $layout
        if($name -eq 'destination-appeared'){
            Check ($failure -and [IO.File]::ReadAllText($layout.Micromamba) -ceq 'unrelated fixture') 'A concurrently added executable was overwritten.'
        }else{
            Check (-not $failure -and [IO.File]::ReadAllText($layout.Micromamba) -ceq 'downloaded fixture') "$name failed to place the verified package-manager executable."
        }
        if($name -eq 'downloaded'){
            Check ($state.micromamba_file_signature -ceq [ScienceRootNative]::Inspect($layout.Micromamba,$false)) 'The actual installer download did not record the executable.'
        }else{
            Check (-not $state.micromamba_file_signature) "$name recorded unproven ownership."
        }
        $passed++;Write-Host "PASS installer executable receipt $name"
    }

    $exeEntry=@((Get-EntryAst '10-remove-micromamba-executable.ps1').EndBlock.Statements |
        Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -or
            $_ -is [Management.Automation.Language.TryStatementAst]})
    $exeScript=Write-TestScript 'remove-exe.ps1' $exeEntry.Extent.Text
    $prompt='Remove this Micromamba executable? [y/N]'

    foreach($name in 'enter','no','approved-home','approved-safe','no-receipt','already-existed','replaced','shared','busy','permission-denied'){
        $fixture.Case=$name
        $root=Join-Path $work $name
        $mode=if($name -eq 'approved-safe'){'Safe'}else{'Home'}
        $bin=if($mode -eq 'Safe'){Join-Path $root 'bin'}else{Join-Path $work "$name-bin"}
        $exe=Join-Path $bin 'micromamba.exe'
        $statePath=Join-Path $root 'installer-state.json'
        foreach($directory in $bin,(Join-Path $root 'envs/analysis'),(Join-Path $root 'pkgs')){
            [void][IO.Directory]::CreateDirectory($directory)
        }
        $data=Join-Path $root 'envs/analysis/data.txt'
        $cache=Join-Path $root 'pkgs/cache.txt'
        $userFile=Join-Path $root 'notes.txt'
        foreach($path in $data,$cache,$userFile){[IO.File]::WriteAllText($path,'keep')}
        [IO.File]::WriteAllText($exe,'inert fixture executable')
        $layout=[pscustomobject]@{Root=$root;Bin=$bin;Mode=$mode;Micromamba=$exe;State=$statePath;Sid='test-user'}
        $fixture.Layout=$layout
        $fixture.Inventory=[pscustomobject]@{Roots=@([pscustomobject]@{Root=$root;Layout=$layout});Problems=@();External=@()}
        $fixture.Shared=$name -eq 'shared'
        $fixture.Processes=if($name -eq 'busy'){@([pscustomobject]@{ProcessId=4242;ExecutablePath=$exe;CommandLine=''})}else{@()}
        [ScienceRootNative]::AllowedRemoval=$exe
        [ScienceRootNative]::ChangedPath=$null
        [ScienceRootNative]::Removals=0
        [ScienceRootNative]::Denied=$name -eq 'permission-denied'
        $state=@{schema_version=2;root=$root;micromamba=$exe;layout_mode=$mode;user_sid=$layout.Sid;
            micromamba_existed_before=($name -eq 'already-existed')}
        if($name -ne 'no-receipt'){$state.micromamba_file_signature=[ScienceRootNative]::Inspect($exe,$false)}
        Write-ScienceTransactionJson $statePath $state
        $stateHash=Get-ScienceFileSha256 $statePath
        $ScienceRelease.MicromambaSha256=Get-ScienceFileSha256 $exe
        $answer=switch($name){'enter'{''} 'no'{'N'} default{'Y'}}
        Set-Replies @($answer)

        $output=& $exeScript 6>&1
        $code=$LASTEXITCODE
        $lines=@($output | ForEach-Object {$_.ToString()})
        $messages=$lines -join [Environment]::NewLine
        if($name -in 'enter','no','approved-home','approved-safe','replaced','permission-denied'){
            $expected=@('Micromamba executable:',$exe,'Micromamba directory:',$root,
                'This Micromamba may also manage other Python environments.',
                'All environments and package caches will be preserved.',$prompt)
            Check (($lines[0..6] -join '|') -ceq ($expected -join '|')) "$name preview was incorrect. $messages"
        }
        $approved=$name -like 'approved-*'
        if($name -in 'enter','no'){
            Check ($code -eq 0 -and $lines[-1] -ceq 'Micromamba removal cancelled.') "$name cancellation failed. $messages"
            Check (-not [IO.File]::Exists((Join-Path $root '.science-update.lock'))) "$name cancellation created a lock."
        }elseif($approved){
            Check ($code -eq 0 -and $lines[-1] -ceq 'The Micromamba executable was removed.') "$name approval failed. $messages"
        }else{
            $reason=switch($name){
                'replaced'{'differs from the file recorded'}
                'shared'{'Shared executable reference'}
                'busy'{'process still references'}
                'permission-denied'{'fixture access denied'}
                default{'ownership .* could not be verified'}
            }
            Check ($code -eq 2 -and $messages -match $reason) "$name guard did not report a failure. $messages"
        }
        $calls=if($approved -or $name -eq 'permission-denied'){1}else{0}
        Check (([IO.File]::Exists($exe) -eq (-not $approved)) -and [ScienceRootNative]::Removals -eq $calls) "$name touched an unexpected target."
        Check ((Get-ScienceFileSha256 $statePath) -ceq $stateHash) "$name changed the ownership receipt."
        foreach($path in $data,$cache,$userFile){Check ([IO.File]::ReadAllText($path) -ceq 'keep') "$name changed preserved data."}
        $passed++;Write-Host "PASS executable $name"
    }

    $totalEntry=(Get-EntryAst '05-remove-micromamba.ps1').EndBlock.Statements |
        Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}
    $totalScript=Write-TestScript 'total.ps1' $totalEntry.Extent.Text
    foreach($name in 'managed-enter','managed-no','external-approved','unsafe'){
        $fixture.Case=$name
        $root=Join-Path $work "$name directory"
        $binary=if($name -like 'managed-*'){Join-Path $work 'home-bin/micromamba.exe'}else{Join-Path $root 'bin/micromamba.exe'}
        $fixture.Layout=[pscustomobject]@{Root=$root;Science=(Join-Path $root 'envs/science');Micromamba=$binary}
        $envs=if($name -like 'managed-*'){@('science','other')}else{@('other')}
        $row=[pscustomobject]@{Root=$root;Layout=$fixture.Layout;Environments=@($envs);Unknown=@();VerifiedExecutable=$true}
        $fixture.Inventory=[pscustomobject]@{Roots=@($row);External=@()}
        $fixture.Plan=[pscustomobject]@{Root=$root;Integration=@{};RemoveRegistrations=@()}
        $fixture.TotalCalls=0
        $fixture.PlannerCalls=0
        $phrase='Yes, I do understand.'
        switch($name){
            'managed-enter'{Set-Replies @('','')}
            'managed-no'{Set-Replies @('','N')}
            'external-approved'{Set-Replies @('1',$root,$phrase,$phrase)}
            'unsafe'{Set-Replies @('1')}
        }

        $output=& $totalScript 6>&1
        $code=$LASTEXITCODE
        $lines=@($output | ForEach-Object {$_.ToString()})
        $messages=$lines -join [Environment]::NewLine
        if($name -eq 'unsafe'){
            Check ($code -eq 2 -and $messages -match 'Total Remove stopped: fixture unsafe target' -and $fixture.TotalCalls -eq 0) 'Unsafe directory reached the total removal operation.'
            Check ($messages -notmatch 'This will permanently delete:') 'Unsafe directory reached the confirmation preview.'
        }else{
            $at=[Array]::IndexOf($lines,'Selected Micromamba directory:')
            $expected=@('Selected Micromamba directory:',$root,'','This will permanently delete:','',
                '- All environments in this directory','- Package caches','- All other files, including user files','',
                'The selected directory and its entire contents will be deleted.')
            Check ($at -ge 0 -and ($lines[$at..($at+9)] -join '|') -ceq ($expected -join '|')) "$name preview was incorrect. $messages"
            if($name -like 'managed-*'){
                Check ($lines[$at+10] -ceq "Micromamba executable outside the selected directory will be preserved: $binary") 'Home preview did not identify the external executable.'
            }
            if($name -eq 'external-approved'){
                Check ($code -eq 0 -and $fixture.TotalCalls -eq 1 -and $fixture.PlannerCalls -eq 2) 'Exact confirmation did not reach the isolated Total Remove mock.'
            }else{
                Check ($code -eq 0 -and $fixture.TotalCalls -eq 0 -and $lines[-1] -ceq 'Cancelled. Nothing was removed.') "$name cancellation failed."
            }
        }
        Check ($fixture.Replies.Count -eq 0) "$name left an expected confirmation prompt uncalled."
        $passed++;Write-Host "PASS Total Remove $name"
    }
    Write-Host "RESULT tests=$passed failed=0"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
