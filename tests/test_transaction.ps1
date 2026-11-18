[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Micromamba,[Parameter(Mandatory=$true)][string]$Fixtures,[string]$TempRoot=[IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'windows/science-integrity.ps1')
Assert-ScienceBundle (Join-Path $root 'windows')
. (Join-Path $root 'windows/science-config.ps1')
. (Join-Path $root 'windows/science-update.ps1')
# The tested executor is unchanged; isolate native user-home registration for fixtures.
$native=(Get-Command Invoke-ScienceNative).ScriptBlock
$work=Join-Path $TempRoot ('science-transaction-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
function Invoke-ScienceNative {
    param([string]$Executable,[string[]]$Arguments,[hashtable]$Environment=@{})
    $Environment['HOME']=Join-Path $work 'native-user';$Environment['USERPROFILE']=$Environment['HOME']
    $result=& $native $Executable $Arguments $Environment
    if($result.ExitCode -ne 0){Write-Host ('Native arguments: '+($Arguments -join ' '))}
    return $result
}
function Get-ScienceFileSha256 {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
. (Join-Path $root 'windows/science-launcher-common.ps1')
$rows=Get-Content -LiteralPath (Join-Path $Fixtures 'records.json') -Raw|ConvertFrom-Json
$results=New-Object Collections.Generic.List[object]
function Assert-True {param([bool]$Value,[string]$Message='Assertion failed');if(-not $Value){throw $Message}}
function Reject {param([scriptblock]$Body,[string]$Pattern);$caught=$null;try{$null=& $Body}catch{$caught=$_};if(-not $caught){throw 'Expected safe rejection'};if($Pattern -and $caught.Exception.Message -notmatch $Pattern){throw "Wrong rejection: $caught"}}
function Case {param([string]$Name,[scriptblock]$Body);try{$null=& $Body;$results.Add(@{name=$Name;pass=$true});Write-Host "PASS $Name"}catch{$results.Add(@{name=$Name;pass=$false;error=$_.ToString()});Write-Host "FAIL ${Name}: $_";Write-Host $_.ScriptStackTrace}}
function New-Layout {
    param([string]$Name)
    $dir=Join-Path $work $Name
    $layout=[pscustomobject]@{Root=$dir;Science=(Join-Path $dir 'envs/science');Pkgs=(Join-Path $dir 'pkgs');Tmp=(Join-Path $dir 'tmp');Micromamba=$Micromamba}
    foreach($p in @($layout.Root,$layout.Pkgs,$layout.Tmp)){[void][IO.Directory]::CreateDirectory($p)}
    Copy-Item (Join-Path $Fixtures '*.tar.bz2') $layout.Pkgs
    [IO.File]::WriteAllText((Join-Path $dir 'config.json'),'{"test":"unchanged"}')
    return $layout
}
function Plan {param([object[]]$Link,[object[]]$Unlink=@());return [pscustomobject]@{success=$true;actions=[pscustomobject]@{LINK=@($Link);UNLINK=@($Unlink)}}}
function Apply {
    param($Layout,$Plan,[scriptblock]$Callback={},[string[]]$RepairNames=@())
    $config=Join-Path $Layout.Root 'config.json'
    $lock=New-ScienceApprovedLock (Get-ScienceRecords $Layout.Science) $Plan $Layout.Science (Get-ScienceFileSha256 $config) (Get-ScienceFileSha256 $Layout.Micromamba) $RepairNames
    $lock=$lock|ConvertTo-Json -Depth 64|ConvertFrom-Json
    $identity=Get-ScienceTextDigest ($lock|ConvertTo-Json -Depth 64 -Compress)
    $directory=Join-Path $Layout.Tmp ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($directory)
    $script:LastLock=$lock;$script:LastDirectory=$directory
    $null=Invoke-ScienceLockedTransaction $Layout $lock $directory $config $identity $Callback
}
$a1=$rows.'science-fixture-a-1.0-0';$a2=$rows.'science-fixture-a-2.0-0';$a21=$rows.'science-fixture-a-2.0-1';$b=$rows.'science-fixture-b-1.0-0';$u=$rows.'science-fixture-user-1.0-0'
try {
    Case 'native-version-is-2.10.0' {Assert-True ((& $Micromamba --version|Out-String).Trim() -ceq '2.10.0')}
    $layout=New-Layout 'native'
    Case 'native-fresh-explicit-create' {Apply $layout (Plan @($a1,$b,$u));Assert-True ((Get-ScienceRecords $layout.Science).Count -eq 3)}
    Case 'native-frozen-update-preserves-user-package' {
        $before=Get-ScienceRecords $layout.Science
        Apply $layout (Plan @($a2) @($before[$a1.name]))
        $after=Get-ScienceRecords $layout.Science;Assert-True ($after[$a1.name].version -ceq '2.0');Assert-True ($after.ContainsKey($u.name));Assert-True ($after[$u.name].url -ceq $u.url)
    }
    Case 'native-same-version-build-change' {$before=Get-ScienceRecords $layout.Science;Apply $layout (Plan @($a21) @($before[$a1.name]));Assert-True ((Get-ScienceRecords $layout.Science)[$a1.name].build -ceq '1')}
    Case 'native-exact-repair' {$payload=Join-Path $layout.Science 'share/science-fixture-b.txt';Remove-Item -LiteralPath $payload;Apply $layout (Plan @($b)) {} @($b.name);Assert-True ([IO.File]::Exists($payload))}
    Case 'cancelled-review-does-not-stage-or-commit' {
        $target=New-Layout 'cancelled';$oldLocal=$env:LOCALAPPDATA
        $review=(Get-Command Confirm-ScienceTransaction).ScriptBlock
        try {
            function Test-ScienceInteractiveConfiguration {return $true}
            function Confirm-ScienceTransaction {param($Lock,[string]$Identity);return $false}
            Reject {Invoke-ScienceReviewedTransaction $target @{} (Plan @($b)) (Join-Path $target.Root 'config.json')} 'cancelled'
            Assert-True (-not (Test-Path -LiteralPath $target.Science));Assert-True (@(Get-ChildItem $target.Tmp).Count -eq 0)
        }finally{Set-Item Function:Confirm-ScienceTransaction $review;$env:LOCALAPPDATA=$oldLocal}
    }
    Case 'native-remove-owned-prefix-preserves-other-environment' {
        $target=New-Layout 'owned-removal'
        Apply $target (Plan @($b))
        $other=Join-Path $target.Root 'envs/independent'
        [void][IO.Directory]::CreateDirectory($other)
        $sentinel=Join-Path $other 'user-data.txt'
        [IO.File]::WriteAllText($sentinel,'preserve')
        [IO.File]::WriteAllText((Join-Path $target.Science '.science-environment-owner'),'test-fixture')
        $result=Invoke-ScienceNative $Micromamba @('env','remove','--no-rc','-r',$target.Root,'-p',$target.Science,'-y')
        Assert-True ($result.ExitCode -eq 0 -and -not [IO.Directory]::Exists($target.Science))
        Assert-True ([IO.File]::ReadAllText($sentinel) -ceq 'preserve')
    }
    Case 'identity-rejects-sha-change' {$changed=$a1|ConvertTo-Json -Depth 32|ConvertFrom-Json;$changed.sha256='a'*64;Reject {Assert-ScienceSameTransaction (Plan @($a1)) (Plan @($changed)) 'test'} 'LINK'}
    Case 'identity-rejects-unlink-change' {Reject {Assert-ScienceSameTransaction (Plan @($a2) @($a1)) (Plan @($a2) @($b)) 'test'} 'UNLINK'}
    Case 'identity-rejects-missing-sha' {$changed=$a1|ConvertTo-Json -Depth 32|ConvertFrom-Json;$changed.sha256='';Reject {Get-ScienceIdentity $changed} 'SHA256'}
    Case 'duplicate-name-rejected' {Reject {Get-ScienceRecordSignature @($a1,$a2)} 'Duplicate'}
    Case 'wrong-prefix-rejected' {Reject {Assert-SciencePlanPrefix ([pscustomobject]@{prefix='/another-prefix'}) $layout.Science} 'prefix'}
    Case 'unrelated-package-removal-rejected' {$before=Get-ScienceRecords $layout.Science;Reject {New-ScienceApprovedLock $before (Plan @() @($before[$u.name])) $layout.Science ('a'*64) ('b'*64)} 'removal'}
    foreach($kind in @('config','memory','lockfile','input','archive','prefix','metadata','binary')) {
        Case ('changed-'+$kind+'-prevents-commit') {
            $target=New-Layout ('tamper-'+$kind)
            if($kind -eq 'metadata'){Apply $target (Plan @($a1,$b))}
            if($kind -eq 'binary'){$copy=Join-Path $target.Root 'mamba-copy';Copy-Item -LiteralPath $Micromamba $copy;$target.Micromamba=$copy}
            $callback={
                switch($kind){
                    config {[IO.File]::AppendAllText((Join-Path $target.Root 'config.json'),' ')}
                    memory {$script:LastLock.after[0].version='99.0'}
                    lockfile {[IO.File]::AppendAllText((Join-Path $script:LastDirectory 'approved-lock.json'),' ')}
                    input {[IO.File]::AppendAllText((Join-Path $script:LastDirectory 'explicit-local.txt'),' ')}
                    archive {$archive=Join-Path (Join-Path $script:LastDirectory 'channel/noarch') $a1.fn;[IO.File]::AppendAllText($archive,'changed')}
                    binary {[IO.File]::AppendAllText($target.Micromamba,'changed')}
                    metadata {[IO.File]::AppendAllText((Join-Path $target.Science 'conda-meta/history'),'changed')}
                    prefix {[void][IO.Directory]::CreateDirectory((Join-Path $target.Science 'conda-meta'));Write-ScienceTransactionJson (Join-Path $target.Science 'conda-meta/intruder.json') $u}
                }
            }
            $proposed=if($kind -eq 'metadata'){Plan @($a2) @((Get-ScienceRecords $target.Science)[$a1.name])}else{Plan @($a1,$b)}
            Reject {Apply $target $proposed $callback} 'changed|input'
            if($kind -eq 'metadata'){Assert-True ((Get-ScienceRecords $target.Science)[$a1.name].version -ceq '1.0')}else{Assert-True (-not [IO.File]::Exists((Join-Path $target.Science 'share/science-fixture-a.txt'))) 'Commit ran despite tampering'}
        }
    }
    Case 'changed-native-preflight-stops-before-commit' {
        $target=New-Layout 'wrong-native-plan';$original=(Get-Command Invoke-ScienceNative).ScriptBlock;$counter=@{commits=0}
        try {
            function Invoke-ScienceNative {
                param([string]$Executable,[string[]]$Arguments,[hashtable]$Environment=@{})
                if($Arguments -contains '--dry-run') {
                    $changed=$b|ConvertTo-Json -Depth 32|ConvertFrom-Json;$changed.build='unapproved'
                    return @{ExitCode=0;Stdout=((Plan @($changed))|ConvertTo-Json -Depth 32);Stderr=''}
                }
                if($Arguments -notcontains '--download-only'){$counter.commits++}
                return & $original $Executable $Arguments $Environment
            }
            Reject {Apply $target (Plan @($b))} 'preflight differs'
            Assert-True ($counter.commits -eq 0);Assert-True (-not (Test-Path -LiteralPath $target.Science))
        }finally{Set-Item Function:Invoke-ScienceNative $original}
    }
    Case 'approved-target-cannot-be-substituted' {
        $target=New-Layout 'approved-target';$other=New-Layout 'substituted-target';$config=Join-Path $target.Root 'config.json'
        $lock=New-ScienceApprovedLock @{} (Plan @($b)) $target.Science (Get-ScienceFileSha256 $config) (Get-ScienceFileSha256 $Micromamba)
        $identity=Get-ScienceTextDigest ($lock|ConvertTo-Json -Depth 64 -Compress)
        $directory=Join-Path $other.Tmp 'must-not-exist'
        Reject {Invoke-ScienceLockedTransaction $other $lock $directory $config $identity} 'target differs'
        Assert-True (-not (Test-Path -LiteralPath $directory));Assert-True (-not (Test-Path -LiteralPath $other.Science))
    }
    Case 'approval-digest-required-before-staging' {
        $target=New-Layout 'unsealed';$lock=New-ScienceApprovedLock @{} (Plan @($b)) $target.Science ('a'*64) ('b'*64)
        $dir=Join-Path $target.Tmp 'unsealed'
        Reject {Invoke-ScienceLockedTransaction $target $lock $dir (Join-Path $target.Root 'config.json') ''} 'identity changed'
        Assert-True (-not (Test-Path -LiteralPath $dir))
    }
    $failed=@($results|Where-Object {-not $_.pass});Write-Host ("RESULT tests="+$results.Count+" passed="+($results.Count-$failed.Count)+" failed="+$failed.Count)
    if($failed.Count){exit 1}
}finally{if($env:SCIENCE_KEEP_TEST_FAILURE){Write-Host ('TEST ROOT: '+$work)}else{Remove-Item -LiteralPath $work -Force -Recurse}}
