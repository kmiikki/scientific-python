[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $root 'shared/StrictJson.cs')
$checks=0
foreach($value in @('0','-0','12','-1.25e+2','9E-07','true','false','null','{"a":[true,false,null,-9.2,0,1200]}','"\u00e4"')){
    [ScienceStrictJson]::Check($value)
    $checks++
}
foreach($value in @('01','-01','1.','-.1','-','1e','1e-','1e+','+1','1E--1','truex','Null','[1 2]','[1,]','[1/*comment*/]','{"a":1,"\u0061":2}','"\u00gz"',('[1,'+[char]0x0662+']'))){
    $rejected=$false
    try{[ScienceStrictJson]::Check($value)}catch{$rejected=$_.Exception.InnerException -is [FormatException]}
    if(-not $rejected){throw 'An invalid JSON fixture was accepted.'}
    $checks++
}
$large='['+('{"build_number":123,"timestamp":1700000000000,"valid":true,"extra":null,"files":["lib/file.dll"]},'*32000)+'0]'
$clock=[Diagnostics.Stopwatch]::StartNew()
[ScienceStrictJson]::Check($large)
$clock.Stop()
if($clock.Elapsed.TotalSeconds -gt 5){throw 'Strict JSON validation took more than 5 seconds for the 3 MB fixture.'}
$checks++
$invalid=$large.Substring(0,$large.Length-2)+'falsee]'
$rejected=$false
try{[ScienceStrictJson]::Check($invalid)}catch{$rejected=$_.Exception.InnerException -is [FormatException]}
if(-not $rejected){throw 'A malformed token at the end of the evidence escaped validation.'}
$checks++
Write-Host ('PASS strict JSON: {0} checks; {1} characters validated in {2} ms' -f $checks,$large.Length,$clock.ElapsedMilliseconds)
