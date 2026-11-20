[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
$base=Join-Path (Split-Path -Parent $PSScriptRoot) 'windows'
. (Join-Path $base 'science-integrity.ps1')
Assert-ScienceBundle $base
. (Join-Path $base 'science-config.ps1')
. (Join-Path $base 'science-common.ps1')
. (Join-Path $base 'science-launcher-common.ps1')
. (Join-Path $base 'science-update.ps1')
$work=Join-Path $TempRoot ('science-progress-fixture-'+[guid]::NewGuid().ToString('n'))
$null=[IO.Directory]::CreateDirectory($work)
$fixture=Join-Path $work 'fake-native.ps1'
[IO.File]::WriteAllText($fixture,@'
Start-Sleep -Seconds 11
[Console]::Out.Write('{"success":true}')
[Console]::Error.Write('isolated warning')
exit 17
'@)
$ps=(Get-Process -Id $PID).Path
try {
    $originalOutput=[Console]::Out
    $output=[IO.StringWriter]::new()
    $progress=$null
    try {
        [Console]::SetOut($output)
        $progress=New-SciencePackageProgress
        $nativeArgs=@('-NoProfile','-NonInteractive','-File',$fixture,'--offline','--file','--json')
        $result=Invoke-ScienceNative $ps $nativeArgs -PackageProgress $progress -NativeActivity 'Micromamba: applying approved transaction'
        if($result.ExitCode -ne 17){throw 'Native exit code missing or changed.'}
        if($result.Stdout.Trim() -cne '{"success":true}' -or $result.Stderr.Trim() -cne 'isolated warning'){
            throw 'Buffered stdout or stderr was lost.'
        }
        Start-Sleep -Seconds 11
    } finally {
        if($progress){$progress.Dispose()}
        [Console]::SetOut($originalOutput)
    }
    $captured=$output.ToString()
    Start-Sleep -Milliseconds 5300
    if($captured -cne $output.ToString()){throw 'The heartbeat continued after disposal.'}
    $beats=[regex]::Matches($captured,'(?m)^\[6/9\] Installing packages +RUNNING +Elapsed: (\d+):(\d\d)  ([^\r\n]+)')
    if($beats.Count -lt 5 -or $beats[0].Groups[1].Value -cne '00' -or $beats[0].Groups[2].Value -cne '00' -or
        $beats[0].Groups[3].Value -cne 'PowerShell: preparing approved transaction'){throw "Missing installation start or periodic progress. $captured"}
    $last=-5
    foreach($beat in $beats){
        $seconds=60*[int]$beat.Groups[1].Value+[int]$beat.Groups[2].Value
        if(($seconds-$last) -lt 4 -or ($seconds-$last) -gt 6){throw "Elapsed times repeated or skipped a heartbeat. $captured"}
        $last=$seconds
    }
    foreach($activity in 'Micromamba: applying approved transaction','PowerShell: processing and verifying Micromamba results'){
        if(@($beats|Where-Object {$_.Groups[3].Value -ceq $activity}).Count -lt 2){throw "Missing heartbeat for $activity. $captured"}
    }
    if($captured -cmatch 'ACTIVE'){throw 'The old process-only status was emitted.'}
    Write-Host 'PASS installation heartbeat before, during and after buffered native execution'
    $root=Join-Path $work 'isolated-root'
    $layout=[pscustomobject]@{Root=$root;Envs=(Join-Path $root 'envs');Science=(Join-Path $root 'envs/science');Micromamba=$fixture}
    $meta=Join-Path $layout.Science 'conda-meta'
    $null=[IO.Directory]::CreateDirectory($meta)
    [IO.File]::WriteAllText((Join-Path $meta 'history'),'test environment')
    [IO.File]::WriteAllText((Join-Path $layout.Envs 'user-file.txt'),'unidentified content')
    function Get-ScienceLayoutStatuses {return [pscustomobject]@{Mode='Home';HasFootprint=$true;Layout=$layout;MicromambaExists=$true}}
    $testHash=(Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
    $inventory=@(Get-ScienceMicromambaInventory $testHash)
    if($inventory.Count -ne 1 -or -not $inventory[0].VerifiedExecutable -or ($inventory[0].Environments -join '|') -cne 'science' -or ($inventory[0].Unknown -join '|') -cne 'user-file.txt'){
        throw ('Inventory mismatch: '+($inventory|ConvertTo-Json -Depth 4 -Compress))
    }
    Write-Host 'PASS supported root inventory reports known and unidentified entries without execution'
} finally {
    if($meta){Remove-Item -LiteralPath (Join-Path $meta 'history'),$meta,$layout.Science -ErrorAction SilentlyContinue}
    if($layout){Remove-Item -LiteralPath (Join-Path $layout.Envs 'user-file.txt'),$layout.Envs,$layout.Root -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -ErrorAction SilentlyContinue
}
