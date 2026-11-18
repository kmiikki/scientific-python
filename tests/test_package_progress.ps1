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
[Console]::Out.WriteLine('{"success":true}')
[Console]::Error.WriteLine('isolated warning')
Start-Sleep -Seconds 6
exit 17
'@)
$ps=Join-Path $PSHOME $(if($PSVersionTable.PSEdition -eq 'Core'){'pwsh.exe'}else{'powershell.exe'})
try {
    $all=@(Invoke-ScienceNative $ps @('-NoProfile','-NonInteractive','-File',$fixture,'--offline','--file','--json') 6>&1)
    $result=@($all|Where-Object {$_ -is [hashtable]})
    if($result.Count -ne 1 -or $result[0].ExitCode -ne 17){throw 'Native exit code missing or changed.'}
    if($result[0].Stdout.Trim() -cne '{"success":true}' -or ($result[0].Stderr -split '\r?\n') -cnotcontains 'isolated warning'){
        throw "Capture mismatch. Stdout: $($result[0].Stdout); stderr: $($result[0].Stderr)"
    }
    if((($all|ForEach-Object {$_.ToString()}) -join "`n") -notmatch '\[6/9\].*Micromamba process: ACTIVE'){throw 'The heartbeat did not appear while the child was active.'}
    Write-Host 'PASS native process heartbeat, stdout, stderr and nonzero exit preserved'
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
