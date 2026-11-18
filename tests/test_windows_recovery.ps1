[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'windows/science-release.ps1')
. (Join-Path $root 'windows/science-update.ps1')

$work=Join-Path $TempRoot ('science-windows-recovery-'+[Guid]::NewGuid().ToString('N'))
$layout=[pscustomobject]@{
    Root=$work; Science=(Join-Path $work 'envs/science'); Tmp=(Join-Path $work 'tmp')
    Pkgs=(Join-Path $work 'pkgs'); State=(Join-Path $work '.science-state.json'); Sid='fixture-user'; Mode='Home'
    Micromamba=(Join-Path $work 'inert-micromamba')
}
$id=[Guid]::NewGuid().ToString('N')
$transaction=Join-Path $layout.Tmp ('science-transaction-'+$id)
[void][IO.Directory]::CreateDirectory($transaction)
[void][IO.Directory]::CreateDirectory($layout.Science)
$record=[pscustomobject]@{name='python';version='3.14.10';build='0';subdir='win-64';sha256=('a'*64)}
$installed=@{python=$record}
$configHash='b'*64
$state=[ordered]@{root=$work;micromamba=$layout.Micromamba;layout_mode='Home';user_sid=$layout.Sid}
$lock=[ordered]@{schema=1;prefix=$layout.Science;config_sha256=$configHash;after=@($record)}
function Check {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw $Message}
}
function Reject {
    param([scriptblock]$Action)
    $rejected=$false
    try {& $Action}catch{$rejected=$true}
    Check $rejected 'Expected the operation to fail closed.'
}
try {
    [IO.File]::WriteAllText($layout.Micromamba,'Plain test data. Never execute.')
    $lock.executable_sha256=Get-ScienceFileSha256 $layout.Micromamba
    $evidence=Join-Path $transaction 'approved-lock.json'
    Write-ScienceTransactionJson $evidence $lock
    Write-ScienceTransactionJson $layout.State $state
    Check ((Get-SciencePreparedInstallationState $layout).user_sid -ceq $layout.Sid) 'Prepared state does not match.'
    Check ((Find-ScienceApprovedRecovery $layout $installed $configHash) -ceq ('science-transaction-'+$id)) 'Exact approved package identities were not found.'
    Check (-not (Find-ScienceApprovedRecovery $layout $installed ('c'*64))) 'Accepted recovery from changed configuration.'
    foreach($change in @('prefix','executable_sha256','after')){
        $wrong=[ordered]@{}
        foreach($key in $lock.Keys){$wrong[$key]=$lock[$key]}
        $wrong[$change]=switch($change){
            prefix {Join-Path $work 'foreign'}
            executable_sha256 {'c'*64}
            after {@([pscustomobject]@{name='python';version='3.14.9';build='0';subdir='win-64';sha256=('a'*64)})}
        }
        Write-ScienceTransactionJson $evidence $wrong
        Check (-not (Find-ScienceApprovedRecovery $layout $installed $configHash)) "Accepted changed recovery $change."
    }
    Reject {Assert-ScienceOwnedPrefix $layout (Get-SciencePreparedInstallationState $layout)}
    $state['science_owner_id']=$id
    Write-ScienceTransactionJson $layout.State $state
    $marker=Join-Path $layout.Science '.science-environment-owner'
    Write-ScienceTransactionJson $marker @{id=$id;sid=$layout.Sid;prefix=$layout.Science}
    Assert-ScienceOwnedPrefix $layout (Get-SciencePreparedInstallationState $layout)
    Write-ScienceTransactionJson $marker @{id=('0'*32);sid=$layout.Sid;prefix=$layout.Science}
    Reject {Assert-ScienceOwnedPrefix $layout (Get-SciencePreparedInstallationState $layout)}
    $manifest=Join-Path $work 'science-packages.json'
    $recorded=@{name='python';version='3.14.10';build_string='0';platform='win-64';sha256=('a'*64)}
    Write-ScienceTransactionJson $manifest @{packages=@($recorded)}
    Assert-ScienceRecordedPrefix $layout $installed
    $recorded.sha256='d'*64
    Write-ScienceTransactionJson $manifest @{packages=@($recorded)}
    Reject {Assert-ScienceRecordedPrefix $layout $installed}

    $requested=@('python','python_abi','spyder','apache-arrow-proc','opencv','ffmpeg')
    $effective=[pscustomobject]@{
        ScientificPackages=$requested; Channels=@('conda-forge'); OpenCV='5.1.0'; FFmpeg='9.0.1'
        MicromambaSha256=(Get-ScienceFileSha256 $layout.Micromamba)
    }
    $script:ScienceRelease=$effective
    $config=Join-Path $work 'configuration.json'
    Write-ScienceTransactionJson $config $effective
    $state.Remove('science_owner_id')
    Write-ScienceTransactionJson $layout.State $state
    Remove-Item -LiteralPath $marker -Force
    $meta=Join-Path $layout.Science 'conda-meta'
    [void][IO.Directory]::CreateDirectory($meta)
    $records=@(
        @('python','3.14.10','0'), @('python_abi','3.14','0_cp314'), @('spyder','6.1.8','0'),
        @('apache-arrow-proc','20.0.0','cpu'), @('opencv','5.1.0','qt6_test'), @('ffmpeg','9.0.2','gpl_test')
    )
    $lock.after=@(foreach($row in $records){
        $name,$version,$build=$row
        $fileName="$name-$version-$build.conda"
        $item=[pscustomobject]@{
            name=$name; version=$version; build=$build; subdir='win-64'; sha256=('a'*64)
            url="https://conda.anaconda.org/conda-forge/win-64/$fileName"; fn=$fileName
        }
        Write-ScienceTransactionJson (Join-Path $meta "$name.json") $item
        $item
    })
    $lock.config_sha256=Get-ScienceFileSha256 $config
    Write-ScienceTransactionJson $evidence $lock
    $calls=@{Finalized=0;Cache=0;Approve=$false}
    function Get-ScienceConfigurationPath {return $config}
    function Get-ScienceEffectiveRelease {return $effective}
    function Assert-ScienceNotInUse {}
    function Test-ScienceInteractiveConfiguration {return $true}
    function Read-Host {if($calls.Approve){return 'yes'};return ''}
    function Invoke-ScienceNative {throw 'Recovery must not start a native package transaction.'}
    function Update-SciencePixbufCache {$calls.Cache++}
    $complete={
        param($PreparedState,$RecoveryEvidence)
        Check ($PreparedState.user_sid -ceq $layout.Sid -and $RecoveryEvidence -ceq ('science-transaction-'+$id)) 'Wrong finalization evidence.'
        $calls.Finalized++
    }
    Reject {Invoke-ScienceEnvironmentSync $layout $requested -AfterSync $complete}
    Check ($calls.Finalized -eq 0 -and $calls.Cache -eq 0) 'Declined recovery changed finalization state.'
    $calls.Approve=$true
    Invoke-ScienceEnvironmentSync $layout $requested -AfterSync $complete
    Check ($calls.Finalized -eq 1 -and $calls.Cache -eq 1) 'Accepted recovery did not complete exactly once.'
    Write-Host 'RESULT recovery and ownership checks passed'
} finally {
    Remove-Item -LiteralPath $work -Force -Recurse
}
