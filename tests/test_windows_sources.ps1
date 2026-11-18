$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'windows/science-integrity.ps1')
. (Join-Path $root 'windows/science-config.ps1')
. (Join-Path $root 'windows/science-transaction.ps1')

$source='https://conda.anaconda.org/conda-forge'
$record=[pscustomobject]@{
    name='_libavif_api'; version='1.3.0'; build='h123_2'; subdir='win-64'
    sha256=('a'*64); fn='_libavif_api-1.3.0-h123_2.conda'
    url="$source/win-64/_libavif_api-1.3.0-h123_2.conda"
}
$layout=[pscustomobject]@{Root='/fixture';Pkgs='/fixture/pkgs';Micromamba='inert'}
$fixture=@{Calls=0;Output=@($record);ExitCode=0}
function Invoke-ScienceNative {
    param($Executable,$Arguments,$Environment)
    $fixture.Calls++
    if($Arguments -cnotcontains 'repoquery' -or $Arguments -cnotcontains $source -or $Arguments -cnotcontains '_libavif_api==1.3.0=h123_2'){
        throw 'Unexpected metadata query.'
    }
    if($Environment['MAMBA_SSL_VERIFY'] -cne 'true'){throw 'TLS verification is required.'}
    return @{ExitCode=$fixture.ExitCode;Stdout=(@{query=@{type='search'};result=@{status='OK';pkgs=$fixture.Output}}|ConvertTo-Json -Depth 12)}
}
function Check {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw $Message}
}
function Reject {
    param([scriptblock]$Action,[string]$Pattern)
    $reason=$null
    try {$null=& $Action}catch{$reason=$_.Exception.Message}
    Check ($reason -match $Pattern) "Expected rejection matching '$Pattern'; received '$reason'."
}
function Assert-Repair {
    param($Old)
    $repair=Get-ScienceSourceRepairs $layout @($Old) @('conda-forge')
    Check ($repair.Count -eq 1 -and $repair[$record.name].url -ceq $record.url) 'Expected a verified canonical URL.'
    Check ($Old.url -cne $record.url) 'Planning must not modify installed records.'
}

Check ((Get-ScienceSourceRepairs $layout @($record) @('conda-forge')).Count -eq 0 -and $fixture.Calls -eq 0) 'Canonical source should need no lookup.'
$legacy=$record.PSObject.Copy()
$legacy.url="file:///C:/mamba/tmp/science-transaction-fixture/channel/win-64/$($record.fn)"
Assert-Repair $legacy
$missing=$record.PSObject.Copy()
$missing.url=''
Assert-Repair $missing
$missing.PSObject.Properties.Remove('fn')
Assert-Repair $missing
Reject {Get-ScienceSourceRepairs $layout @($legacy) @('custom')} 'Conda-forge is required'
foreach($url in @('http://conda.anaconda.org/test','ftp://host/unsafe','https://secret@conda.anaconda.org/unsafe','C:/explicit/local/package.conda','file:///C:/mamba/foreign.conda')) {
    $unsafe=$record.PSObject.Copy()
    $unsafe.url=$url
    Reject {Get-ScienceSourceRepairs $layout @($unsafe) @('conda-forge')} 'Unsafe|stable HTTPS|filename'
}
foreach($field in @('version','build','subdir','sha256','url')) {
    $candidate=$record.PSObject.Copy()
    $candidate.$field=switch($field){
        version {'1.4.0'}
        build {'different'}
        subdir {'noarch'}
        sha256 {'b'*64}
        url {"https://mirror.invalid/win-64/$($record.fn)"}
    }
    $fixture.Output=@($candidate)
    Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} 'could not verify a unique source'
}
$fixture.Output=@($record,$record)
Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} 'could not verify a unique source'
$fixture.Output=@()
Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} 'could not verify a unique source'
$fixture.ExitCode=7
Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} 'metadata query failed'
$missing.sha256=''
Reject {Get-ScienceSourceRepairs $layout @($missing) @('conda-forge')} 'SHA256 identity'
Write-Host 'RESULT package-source checks passed'
