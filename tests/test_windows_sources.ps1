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
$fixture=@{Calls=0;Output=@($record);ExitCode=0;Spec='_libavif_api==1.3.0=h123_2';BadJson=$false}
function Invoke-ScienceNative {
    param($Executable,$Arguments,$Environment)
    $fixture.Calls++
    if($Arguments -cnotcontains 'repoquery' -or $Arguments -cnotcontains $source -or $Arguments -cnotcontains $fixture.Spec){
        throw 'Unexpected metadata query.'
    }
    if($Environment['MAMBA_SSL_VERIFY'] -cne 'true'){throw 'TLS verification is required.'}
    if($fixture.BadJson){return @{ExitCode=0;Stdout='{"secret":"never-log-this",'} }
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
foreach($field in @('version','build','subdir','sha256','fn','url')) {
    $candidate=$record.PSObject.Copy()
    $candidate.$field=switch($field){
        version {'1.4.0'}
        build {'different'}
        subdir {'noarch'}
        sha256 {'b'*64}
        fn {'different.conda'}
        url {"https://mirror.invalid/win-64/$($record.fn)"}
    }
    $fixture.Output=@($candidate)
    $label=switch($field){subdir {'subdirectory'} fn {'filename'} default {$field}}
    Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} "candidates=1, verified=0.*${label}=1"
}
$fixture.Output=@($record,$record)
Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} 'candidates=2, verified=2'
$fixture.Output=@()
Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} 'candidates=0, verified=0'
$fixture.ExitCode=7
Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} 'metadata query failed \(batch 1, 1 requests, exit 7\)'
$missing.sha256=''
Reject {Get-ScienceSourceRepairs $layout @($missing) @('conda-forge')} 'SHA256 identity'
$fixture.ExitCode=0
$fixture.BadJson=$true
Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} 'invalid JSON \(batch 1, 1 requests\)\.$'
$fixture.BadJson=$false
$fixture.Output=$record
Reject {Get-ScienceSourceRepairs $layout @($legacy) @('conda-forge')} 'did not return a valid package list'

# Real Micromamba 2.10.0 returns %21 for the epoch delimiter in the URL
# but leaves the version and filename literal.
$x264=[pscustomobject]@{
    name='x264'; version='1!164.3095'; build='pl5321h71a6e3e_3'; subdir='win-64'
    sha256='e43f0cd29479ec1b53f62986b59cd6213953ab22ca6335fca7a5fcc63463f58e'
    fn='x264-1!164.3095-pl5321h71a6e3e_3.conda'
    url='https://conda.anaconda.org/conda-forge/win-64/x264-1%21164.3095-pl5321h71a6e3e_3.conda'
}
$old=$x264.PSObject.Copy()
$old.url='file:///C:/fixture/'+$old.fn
$fixture.Spec='x264==1!164.3095=pl5321h71a6e3e_3'
$fixture.Output=@($x264)
$repair=Get-ScienceSourceRepairs $layout @($old) @('conda-forge')
Check ($repair.x264.url -ceq $x264.url -and $repair.x264.fn -ceq $old.fn -and $old.url.StartsWith('file:')) 'Encoded x264 filename did not verify without changing its input.'
$literal=$x264.PSObject.Copy()
$literal.url=$literal.url.Replace('%21','!')
$fixture.Output=@($x264,$literal)
Reject {Get-ScienceSourceRepairs $layout @($old) @('conda-forge')} 'candidates=2, verified=2'
foreach($badUrl in @(
    $x264.url.Replace('%21','%2521'), $x264.url.Replace('/x264','/%2e%2e%2fx264'),
    $x264.url.Replace('conda-forge/','conda%2dforge/'), $x264.url.Replace('conda.anaconda.org/','conda.anaconda.org:443/'),
    $x264.url.Replace('https://','https://user:secret@'), ($x264.url+'?token=secret'), ($x264.url+'#secret')
)){
    $candidate=$x264.PSObject.Copy()
    $candidate.url=$badUrl
    $fixture.Output=@($candidate)
    Reject {Get-ScienceSourceRepairs $layout @($old) @('conda-forge')} 'candidates=1, verified=0, rejected at first check: (url|filename)=1\.$'
}
Write-Host 'RESULT package-source checks passed'
