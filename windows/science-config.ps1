# Native PowerShell 5.1-compatible configuration and conservative migration.
function Read-ScienceJson {
    param([string]$Path)
    Assert-ScienceRegularPath $Path
    try {
        $encoding=New-Object Text.UTF8Encoding($false,$true)
        $text=$encoding.GetString([IO.File]::ReadAllBytes($Path))
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {$text=$text.Substring(1)}
        if (-not ('ScienceStrictJson' -as [type])) { Add-Type -Path (Join-Path (Get-ScienceSharedDirectory) 'StrictJson.cs') -ErrorAction Stop }
        [ScienceStrictJson]::Check($text)
        return ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch { throw "Cannot read JSON ${Path}: $($_.Exception.Message)" }
}
function Get-ScienceSpecName {
    param([object]$Spec,[object[]]$Channels=$null)
    if ($Spec -isnot [string] -or -not $Spec -or $Spec -cne $Spec.Trim() -or $Spec -match '[\x00-\x1f]') { throw 'Package request must be a nonempty string without whitespace or control characters.' }
    if ($Spec -cnotmatch '^(?:(?<channel>[^\s]+)::)?(?<name>[A-Za-z0-9_][A-Za-z0-9_.-]*)(?<tail>.*)$') { throw "Invalid package request: $Spec" }
    $channel=$Matches['channel'];$name=$Matches['name'].ToLowerInvariant();$tail=$Matches['tail']
    if ($Channels -and $channel -and $Channels -cnotcontains $channel) { throw "Package channel is not in Channels: $Spec" }
    if ($tail -and '[=<>!~ '.IndexOf($tail[0]) -lt 0) { throw "Invalid MatchSpec after package name: $Spec" }
    $quote=[char]0;$depth=0
    foreach ($c in $tail.ToCharArray()) {
        if ($c -eq [char]39 -or $c -eq [char]34) {
            if ($quote -eq $c) {$quote=[char]0} elseif ($quote -eq [char]0) {$quote=$c}
        } elseif ($quote -eq [char]0) {
            if ($c -eq '[') {$depth++} elseif ($c -eq ']') {$depth--}
            if ($depth -lt 0 -or $depth -gt 1) {throw "Unbalanced MatchSpec brackets: $Spec"}
        }
    }
    if ($quote -ne [char]0 -or $depth -ne 0) {throw "Unbalanced MatchSpec quotes/brackets: $Spec"}
    if ($tail -and @('=','==','>=','<=','>','<','!=','~=','[]') -ccontains $tail.Trim()) {throw "Missing MatchSpec constraint: $Spec"}
    foreach ($m in [regex]::Matches($tail,'(?:\[|,)\s*channel\s*=\s*[''"]?([^,\]''" ]+)')) {
        if ($Channels -and $Channels -cnotcontains $m.Groups[1].Value) {throw "Package channel is not in Channels: $($m.Groups[1].Value)"}
    }
    return $name
}
function Assert-ScienceConfiguration {
    param($Value)
    $schema=Read-ScienceJson (Join-Path (Get-ScienceSharedDirectory) 'science-release.schema.json')
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {throw 'Configuration must be an object.'}
    $keys=@($Value.PSObject.Properties.Name)
    if ($keys.Count -ne 3) {throw 'Expected only SchemaVersion, Channels and ScientificPackages.'}
    foreach ($key in $keys) {if (@($schema.required) -cnotcontains $key) {throw "Unexpected configuration field: $key"}}
    if (($Value.SchemaVersion -isnot [int] -and $Value.SchemaVersion -isnot [long]) -or $Value.SchemaVersion -ne 1) {throw 'Unsupported SchemaVersion; expected integer 1.'}
    foreach ($field in @('Channels','ScientificPackages')) {
        $items=$Value.$field
        if ($items -isnot [Array] -or $items.Count -eq 0) {throw "$field must be a nonempty list of strings."}
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($item in $items) {
            if ($item -isnot [string] -or -not $item -or $item -cne $item.Trim() -or $item -match '[\x00-\x1f]') {throw "$field must contain nonempty strings."}
            if (-not $seen.Add($item)) {throw "Duplicate entry in $field."}
        }
    }
    foreach ($channel in $Value.Channels) {
        if ($channel -cnotmatch '^(?:[A-Za-z0-9_][A-Za-z0-9_./-]*|https://[^\s\[\]<>]+)$') {throw "Invalid channel name or HTTPS URL: $channel"}
    }
    $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($spec in $Value.ScientificPackages) {
        $name=Get-ScienceSpecName $spec $Value.Channels
        if (-not $names.Add($name)) {throw "Duplicate/conflicting package ${name}; use one request per package."}
    }
    return $Value
}
function Get-ScienceConfigurationPath {
    if (-not $env:LOCALAPPDATA) {throw 'LOCALAPPDATA is required for the persistent user configuration.'}
    return Join-Path $env:LOCALAPPDATA 'ScientificPython/science-release.json'
}
function Get-ScienceDefaultConfiguration {
    $value=Read-ScienceJson (Join-Path (Get-ScienceSharedDirectory) 'science-release.default.json')
    $policy=Read-ScienceJson (Join-Path $PSScriptRoot 'science-installer-release.json')
    # A single common 42-request template; only the documented platform FFmpeg floor differs.
    $value.ScientificPackages=@($value.ScientificPackages | ForEach-Object {
        if ((Get-ScienceSpecName $_) -eq 'ffmpeg') {"ffmpeg[version='>=$($policy.FFmpegMinimum),<10',build='gpl*']"} else {$_}
    })
    return Assert-ScienceConfiguration $value
}
function Get-ScienceLegacyWindowsRequests {
    param($Value,[string]$Source)
    if (-not $Source -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) {throw 'Legacy Windows JSON has no package list and its matching science-release.ps1 is missing. Restore both original files from that installation; migration stopped. Existing files and Science environment were not changed.'}
    Assert-ScienceRegularPath $Source
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {throw 'Legacy PowerShell package source is not valid; migration stopped.'}
    $functions=@($ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'Get-SciencePackageSpecs'},$true))
    if ($functions.Count -ne 1) {throw 'Expected one original Get-SciencePackageSpecs function; migration stopped.'}
    $statements=@($functions[0].Body.EndBlock.Statements)
    if ($statements.Count -ne 1 -or $statements[0] -isnot [Management.Automation.Language.PipelineAst]) {throw 'Dynamic legacy package function cannot be migrated safely.'}
    $array=$statements[0].PipelineElements[0].Expression
    if ($array -isnot [Management.Automation.Language.ArrayExpressionAst]) {throw 'Legacy package function must contain a literal request array.'}
    $result=@()
    foreach ($statement in $array.SubExpression.Statements) {
        if ($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1 -or $statement.PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst]) {throw 'Dynamic legacy package source is not executed; migration stopped.'}
        $expr=$statement.PipelineElements[0].Expression
        if ($expr -isnot [Management.Automation.Language.StringConstantExpressionAst] -and $expr -isnot [Management.Automation.Language.ExpandableStringExpressionAst]) {throw 'Unsupported legacy request expression; migration stopped.'}
        $spec=$expr.Value
        if ($expr -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
            $spec=$spec.Replace('$($script:ScienceRelease.Python.Replace(''.'',''''))',([string]$Value.Python).Replace('.',''))
            foreach ($key in @('Python','Spyder','OpenCV','OpenCVMaxExclusive','FFmpeg','FFmpegMaxExclusive')) {
                if ($Value.$key -isnot [string] -or [string]$Value.$key -notmatch '^\d+(?:\.\d+){0,3}$') {throw "Invalid legacy version: $key"}
                $spec=$spec.Replace(('$($script:ScienceRelease.'+$key+')'),[string]$Value.$key)
            }
            if ($spec.Contains('$')) {throw 'Unknown legacy interpolation is not executed; migration stopped.'}
        }
        $result+=,$spec
    }
    return ,$result
}
function Convert-ScienceLegacyConfiguration {
    param($Value,[string]$LegacySource)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {throw 'Configuration must be a JSON object.'}
    if (@($Value.PSObject.Properties.Name) -ccontains 'SchemaVersion') {return Assert-ScienceConfiguration $Value}
    if (@($Value.PSObject.Properties.Name) -ccontains 'ScientificPackages') {
        # A user-supplied full request list is authoritative; v12's version-only format has no list.
        if ($Value.ScientificPackages -isnot [array]) {throw 'Legacy ScientificPackages must be an array.'}
        $packages=@($Value.ScientificPackages)
        $arrow='cpu'
        if (@($Value.PSObject.Properties.Name) -ccontains 'ArrowVariant') {$arrow=$Value.ArrowVariant}
        if ($arrow -isnot [string] -or $arrow -notmatch '^[A-Za-z0-9_*.-]+$') {throw 'Invalid legacy ArrowVariant.'}
        $foundation=@(
            "python=$($Value.Python)","python_abi=$($Value.Python)=*_cp$(([string]$Value.Python).Replace('.',''))","spyder=$($Value.Spyder)","apache-arrow-proc=*=$arrow",
            "opencv[version='>=$($Value.OpenCV),<$($Value.OpenCVMaxExclusive)',build='qt6*']","ffmpeg[version='>=$($Value.FFmpeg),<$($Value.FFmpegMaxExclusive)',build='gpl*']"
        )
        foreach ($key in @('Python','Spyder','OpenCV','OpenCVMaxExclusive','FFmpeg','FFmpegMaxExclusive')) {if ($Value.$key -isnot [string] -or [string]$Value.$key -notmatch '^\d+(?:\.\d+){0,3}$') {throw "Invalid legacy version: $key"}}
        $names=@($packages | ForEach-Object {Get-ScienceSpecName $_})
        $requests=@($foundation | Where-Object {$names -cnotcontains (Get-ScienceSpecName $_)})+$packages
    } else {$requests=Get-ScienceLegacyWindowsRequests $Value $LegacySource}
    $channels=@('conda-forge');if (@($Value.PSObject.Properties.Name) -ccontains 'Channels') {$channels=$Value.Channels}
    return Assert-ScienceConfiguration ([pscustomobject]@{SchemaVersion=1;Channels=$channels;ScientificPackages=@($requests)})
}
function Set-ScienceConfigBytes {
    param([string]$Path,[byte[]]$Bytes,[byte[]]$ExpectedBytes=$null)
    $parent=Split-Path -Parent $Path
    $cursor=$parent
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $info=Get-Item -LiteralPath $cursor -Force
            if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw "Redirected configuration directory: $cursor"}
        }
        $next=Split-Path -Parent $cursor
        if ($next -eq $cursor) {break};$cursor=$next
    }
    [void][IO.Directory]::CreateDirectory($parent)
    if (Test-Path -LiteralPath $Path) {Assert-ScienceRegularPath $Path}
    $tmp=Join-Path $parent ('.science-config-'+[Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllBytes($tmp,$Bytes)
        if ($null -ne $ExpectedBytes) {
            Assert-ScienceRegularPath $Path
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -cne [Convert]::ToBase64String($ExpectedBytes)) {throw 'Configuration changed during review; no replacement was made. Start again.'}
        }
        if ([IO.File]::Exists($Path)) {[IO.File]::Replace($tmp,$Path,[NullString]::Value)} else {[IO.File]::Move($tmp,$Path)}
    } finally {if ([IO.File]::Exists($tmp)) {[IO.File]::Delete($tmp)}}
}
function Get-ScienceConfigurationOrigins {
    param([string]$Path,[string]$Root)
    $receipt=Join-Path (Split-Path -Parent $Path) 'science-config-origins.json'
    $value=[pscustomobject]@{SchemaVersion=1;Roots=@()}
    if (Test-Path -LiteralPath $receipt) {$value=Read-ScienceJson $receipt}
    if ($null -eq $value -or $value.SchemaVersion -ne 1 -or $value.Roots -isnot [array] -or @($value.PSObject.Properties.Name).Count -ne 2) {throw 'Invalid configuration origin record; restore original metadata. No environment changes started.'}
    foreach($item in $value.Roots){if($item -isnot [string]){throw 'Invalid configuration origin record.'}}
    return [pscustomobject]@{Path=$receipt;Value=$value;Key=[IO.Path]::GetFullPath($Root).ToLowerInvariant()}
}
function Set-ScienceConfigurationOrigin {
    param([string]$Path,[string]$Root)
    if (-not $Root) {return}
    $origin=Get-ScienceConfigurationOrigins $Path $Root
    if ($origin.Value.Roots -cnotcontains $origin.Key) {
        $origin.Value.Roots+=,$origin.Key
        Set-ScienceConfigBytes $origin.Path ((New-Object Text.UTF8Encoding($false)).GetBytes(($origin.Value|ConvertTo-Json -Depth 5)+"`n"))
    }
}
function Initialize-ScienceConfiguration {
    param([string]$Path=(Get-ScienceConfigurationPath),[string]$Root,[string]$LegacyPath)
    if ($LegacyPath -and -not (Test-Path -LiteralPath $LegacyPath -PathType Leaf) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {throw 'Explicit legacy configuration is missing; migration stopped.'}
    if ($Root) {$null=Get-ScienceConfigurationOrigins $Path $Root}
    $candidates=@($Path)
    if ($LegacyPath) {$candidates+=,$LegacyPath}
    $candidates+=,(Join-Path $PSScriptRoot 'science-release.json')
    if ($Root) {$candidates+=,(Join-Path $Root 'science-release.json')}
    $source=$null
    foreach ($candidate in $candidates) {if (Test-Path -LiteralPath $candidate) {$source=$candidate;break}}
    if (-not $source) {
        if ($Root -and (Test-Path -LiteralPath (Join-Path $Root 'envs/science'))) {throw 'Existing Science environment has no recoverable original configuration. Restore science-release.json and its matching original science-release.ps1; migration stopped. No environment changes were made.'}
        $value=Get-ScienceDefaultConfiguration
    } else {
        $old=Read-ScienceJson $source
        $legacySource=Join-Path (Split-Path -Parent $source) 'science-release.ps1'
        $value=Convert-ScienceLegacyConfiguration $old $legacySource
        if ($source -eq $Path -and @($old.PSObject.Properties.Name) -ccontains 'SchemaVersion') {
            if ($Root -and (Test-Path -LiteralPath (Join-Path $Root 'envs/science'))) {
                $origin=Get-ScienceConfigurationOrigins $Path $Root
                if ($origin.Value.Roots -cnotcontains $origin.Key) {
                    $previous=$null
                    foreach($candidate in @($candidates | Select-Object -Skip 1)) {if(Test-Path -LiteralPath $candidate){$previous=$candidate;break}}
                    if (-not $previous) {throw 'Existing Science environment has no matching original configuration for this active file. Restore its original science-release.json and matching science-release.ps1; migration stopped. No configuration or environment changes were made.'}
                    $prior=Convert-ScienceLegacyConfiguration (Read-ScienceJson $previous) (Join-Path (Split-Path -Parent $previous) 'science-release.ps1')
                    $same=($prior.SchemaVersion -eq $value.SchemaVersion) -and ((@($prior.Channels) -join [char]0) -ceq (@($value.Channels) -join [char]0)) -and ((@($prior.ScientificPackages) -join [char]0) -ceq (@($value.ScientificPackages) -join [char]0))
                    if (-not $same) {throw 'Existing installation configuration differs from the unassociated active file. Migration stopped; no user preferences were overwritten.'}
                }
            }
            Set-ScienceConfigurationOrigin $Path $Root
            return $value
        }
        $bytes=[IO.File]::ReadAllBytes($source);$sha=[Security.Cryptography.SHA256]::Create()
        try {$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
        $backup=Join-Path (Split-Path -Parent $Path) ('science-release.legacy-'+$hash+'.json')
        if (Test-Path -LiteralPath $backup) {
            Assert-ScienceRegularPath $backup
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -cne [Convert]::ToBase64String($bytes)) {throw 'Legacy backup collision; migration stopped.'}
        } else {Set-ScienceConfigBytes $backup $bytes}
    }
    $text=($value | ConvertTo-Json -Depth 32)+"`n"
    Set-ScienceConfigBytes $Path ((New-Object Text.UTF8Encoding($false)).GetBytes($text))
    Set-ScienceConfigurationOrigin $Path $Root
    return $value
}
function Get-ScienceEffectiveRelease {
    $path=Get-ScienceConfigurationPath
    $value=if (Test-Path -LiteralPath $path) {Convert-ScienceLegacyConfiguration (Read-ScienceJson $path) (Join-Path (Split-Path -Parent $path) 'science-release.ps1')} else {Get-ScienceDefaultConfiguration}
    $policy=Read-ScienceJson (Join-Path $PSScriptRoot 'science-installer-release.json')
    foreach ($key in @('SchemaVersion','Channels','ScientificPackages')) {$policy | Add-Member -NotePropertyName $key -NotePropertyValue $value.$key -Force}
    return $policy
}
function Assert-ScienceWorkflowConfiguration {
    param($Configuration)
    $names=@($Configuration.ScientificPackages | ForEach-Object {Get-ScienceSpecName $_ $Configuration.Channels})
    foreach ($name in @('python','python_abi','spyder','apache-arrow-proc','opencv','ffmpeg')) {
        if ($names -cnotcontains $name) {throw "This installer phase requires foundation package ${name}. Configuration is preserved; no package changes started."}
    }
}
function Get-ScienceChannelArguments {
    param($Configuration)
    $result=@('--no-rc','--override-channels','--strict-channel-priority')
    foreach ($channel in $Configuration.Channels) {$result+=@('-c',$channel)}
    return $result
}

function Test-ScienceInteractiveConfiguration {
    if ($Host.Name -ne 'ConsoleHost' -or -not [Environment]::UserInteractive) {return $false}
    foreach($argument in [Environment]::GetCommandLineArgs()) {
        if($argument.Length -ge 5 -and '-NonInteractive'.StartsWith($argument,[StringComparison]::OrdinalIgnoreCase)){return $false}
    }
    try {return -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected} catch {return $false}
}
function Show-ScienceNewRootConfiguration {
    param($Layout,[string]$Path=(Get-ScienceConfigurationPath))
    if(Test-Path -LiteralPath $Layout.Science){return}
    if(-not (Test-Path -LiteralPath $Path)){
        Write-Host 'The new root will start with release defaults if no legacy configuration is found. Release defaults do not request PyTorch.'
        return
    }
    Assert-ScienceRegularPath $Path
    $original=[IO.File]::ReadAllBytes($Path)
    $saved=Read-ScienceJson $Path
    if(@($saved.PSObject.Properties.Name) -cnotcontains 'SchemaVersion'){
        Write-Host 'The new root would use the existing saved legacy configuration. Review its migration before changing package requests.'
        return
    }
    $null=Assert-ScienceConfiguration $saved
    $default=Get-ScienceDefaultConfiguration
    Write-Host "The new root would use saved package requests from $Path"
    Write-Host ('Saved PyTorch choice: '+(Get-SciencePyTorchBackend @($saved.ScientificPackages)).ToUpperInvariant())
    if((($saved.Channels -join '|') -ceq ($default.Channels -join '|')) -and (($saved.ScientificPackages -join '|') -ceq ($default.ScientificPackages -join '|'))){return}
    $origin=Get-ScienceConfigurationOrigins $Path $Layout.Root
    if(@($origin.Value.Roots|Where-Object {$_ -ine $origin.Key}).Count -or @(Get-ScienceLayoutStatuses | Where-Object {$_.Layout.Root -ine $Layout.Root -and $_.ScienceExists}).Count){
        Write-Host 'Reset unavailable because another installation may use this configuration. The saved requests are preserved.'
        return
    }
    if(-not (Test-ScienceInteractiveConfiguration)){return}
    if((Read-Host 'Reset saved requests to release defaults (no PyTorch)? [y/N]').Trim() -notmatch '^(?i:y|yes)$'){return}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=[BitConverter]::ToString($sha.ComputeHash($original)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $backup=Join-Path (Split-Path -Parent $Path) ('science-release.pre-reset-'+$hash+'.json')
    if(Test-Path -LiteralPath $backup){
        Assert-ScienceRegularPath $backup
        if([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -cne [Convert]::ToBase64String($original)){throw 'Configuration backup collision.'}
    }else{Set-ScienceConfigBytes $backup $original}
    $text=($default|ConvertTo-Json -Depth 32)+"`n"
    Set-ScienceConfigBytes $Path ((New-Object Text.UTF8Encoding($false)).GetBytes($text)) -ExpectedBytes $original
    Write-Host "Previous configuration saved to $backup"
}
function Get-ScienceMissingReleasePackages {
    param($Configuration)
    $null=Assert-ScienceConfiguration $Configuration
    $names=@($Configuration.ScientificPackages|ForEach-Object {Get-ScienceSpecName $_ $Configuration.Channels})
    return @( (Get-ScienceDefaultConfiguration).ScientificPackages|Where-Object {$names -cnotcontains (Get-ScienceSpecName $_)} )
}
function Update-ScienceReleasePackages {
    param([string]$Path=(Get-ScienceConfigurationPath),[bool]$Interactive=$false,[scriptblock]$Reviewer=$null)
    Assert-ScienceRegularPath $Path
    $original=[IO.File]::ReadAllBytes($Path)
    $value=Assert-ScienceConfiguration (Read-ScienceJson $Path)
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -cne [Convert]::ToBase64String($original)){throw 'Configuration changed while reading; start again.'}
    $missing=@(Get-ScienceMissingReleasePackages $value)
    if(-not $missing.Count){Write-Host 'Release defaults: all default package names are requested; user constraints/channels are retained.';return $value}
    Write-Host ('Release-default requests absent from your configuration: '+($missing -join ', '))
    Write-Host 'Only approved missing requests will be appended. Existing requests, constraints and channels are retained.'
    if(-not $Interactive){Write-Host 'Non-interactive: configuration preserved; release-default differences remain.';return $value}
    $prompt='Add these release requests to your configuration? [y/N]'
    $answer=if($Reviewer){& $Reviewer $prompt}else{Read-Host $prompt}
    if(([string]$answer).Trim() -notmatch '^(?i:y|yes)$'){Write-Host 'Configuration preserved; installation/verification will use your effective configuration, with release-default differences reported separately.';return $value}
    $candidate=[pscustomobject]@{SchemaVersion=$value.SchemaVersion;Channels=@($value.Channels);ScientificPackages=@($value.ScientificPackages)+$missing}
    $null=Assert-ScienceConfiguration $candidate
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($candidate|ConvertTo-Json -Depth 32)+"`n")
    # File.Replace retains the destination Windows ACL; no backup series is created.
    Set-ScienceConfigBytes -Path $Path -Bytes $bytes -ExpectedBytes $original
    Write-Host 'Approved release requests added to configuration. The package transaction still requires separate approval.'
    return $candidate
}

function Get-SciencePyTorchBackend {
    param([string[]]$Packages)
    $backends=@(foreach($spec in $Packages) {
        switch (Get-ScienceSpecName $spec) {
            'pytorch-cpu' {'cpu'}
            'pytorch-gpu' {'cuda'}
            'pytorch' {
                $build=[regex]::Match($spec,'(?:\[|,)\s*build\s*=\s*(?<quote>[''"]?)(?<build>[\w.*+-]+)\k<quote>\s*(?=[,\]])')
                if(-not $build.Success){
                    $build=[regex]::Match($spec,'(?i)^(?:[^\s]+::)?pytorch(?:==?[\w.*+!-]+=|\s+[^\s\[]+\s+)(?<build>[\w.*+-]+)\s*$')
                }
                $value=$build.Groups['build'].Value
                if($value.StartsWith('cpu',[StringComparison]::Ordinal)){'cpu'}
                elseif($value.StartsWith('cuda',[StringComparison]::Ordinal)){'cuda'}
                else{'automatic'}
            }
        }
    })
    $explicit=@($backends|Where-Object {$_ -cne 'automatic'}|Select-Object -Unique)
    if($explicit.Count -gt 1){return 'conflicting'}
    if($explicit.Count){return $explicit[0]}
    if($backends.Count){return 'automatic'}
    return 'none'
}

function Test-ScienceNvidiaDevice {
    $nvidia=Get-Command nvidia-smi.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $nvidia){return $false}
    try {
        $devices=& $nvidia.Source -L
        return ($LASTEXITCODE -eq 0 -and [bool]($devices -match '^GPU \d+:'))
    } catch {return $false}
}

function Set-SciencePyTorchRequest {
    param([ValidateSet('cpu','cuda','remove')][string]$Choice,
          [string]$Path=(Get-ScienceConfigurationPath),[byte[]]$ExpectedBytes=$null)
    Assert-ScienceRegularPath $Path
    $original=[IO.File]::ReadAllBytes($Path)
    $fingerprint=[Convert]::ToBase64String($original)
    $value=Assert-ScienceConfiguration (Read-ScienceJson $Path)
    if(($null -ne $ExpectedBytes -and [Convert]::ToBase64String($ExpectedBytes) -cne $fingerprint) -or
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -cne $fingerprint){
        throw 'Configuration changed during review; start again.'
    }
    $packages=@($value.ScientificPackages)
    $torchNames=@('pytorch','pytorch-cpu','pytorch-gpu')
    $torchSpecs=@($packages|Where-Object {$torchNames -ccontains (Get-ScienceSpecName $_)})
    if($Choice -ceq 'remove'){
        if(-not $torchSpecs.Count){return}
        $packages=@($packages|Where-Object {$torchSpecs -cnotcontains $_})
    } else {
        if((Get-SciencePyTorchBackend $torchSpecs) -ceq $Choice){return}
        if(@($torchSpecs|Where-Object {(Get-ScienceSpecName $_) -cne 'pytorch'}).Count){
            throw 'Remove the previous PyTorch add-on request before selecting a different backend.'
        }
        $build=$Choice+'*'
        if(-not $torchSpecs.Count){
            $packages+="pytorch[build='$build']"
        } else {
            $spec=$torchSpecs[0]
            $match=[regex]::Match($spec,'(?:\[|,)\s*build\s*=\s*(?<quote>[''"]?)(?<build>[\w.*+-]+)\k<quote>\s*(?=[,\]])')
            $oldBuild=$match.Groups['build']
            if($match.Success -and $oldBuild.Value -cin @('cpu*','cuda*')){
                $chosen=$spec.Substring(0,$oldBuild.Index)+$build+$spec.Substring($oldBuild.Index+$oldBuild.Length)
            } elseif($match.Success -or $spec -cmatch '(?:\[|,)\s*build\s*=' -or
                $spec -cmatch '(?i)^(?:[^\s]+::)?pytorch(?:==?[\w.*+!-]+=|\s+[^\s\[]+\s+)([\w.*+-]+)\s*$'){
                throw 'The PyTorch request has an explicit build constraint. Review it before switching backends.'
            } elseif($spec.EndsWith(']')) {
                $chosen=$spec.Substring(0,$spec.Length-1)+",build='$build']"
            } else {
                $chosen=$spec+"[build='$build']"
            }
            $packages=@($packages|ForEach-Object {if($_ -ceq $spec){$chosen}else{$_}})
        }
    }
    $candidate=[pscustomobject]@{SchemaVersion=$value.SchemaVersion;Channels=@($value.Channels);ScientificPackages=$packages}
    $null=Assert-ScienceConfiguration $candidate
    Assert-ScienceWorkflowConfiguration $candidate

    $sha=[Security.Cryptography.SHA256]::Create()
    try {$digest=[BitConverter]::ToString($sha.ComputeHash($original)).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose()}
    $backup=Join-Path (Split-Path -Parent $Path) ('science-release.optional-'+$digest+'.json')
    if(Test-Path -LiteralPath $backup){
        Assert-ScienceRegularPath $backup
        if([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -cne $fingerprint){
            throw "Optional-package backup collision: $backup"
        }
    } else {
        Set-ScienceConfigBytes -Path $backup -Bytes $original
    }
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($candidate|ConvertTo-Json -Depth 32)+[Environment]::NewLine)
    Set-ScienceConfigBytes -Path $Path -Bytes $bytes -ExpectedBytes $original
    return $backup
}

function Select-ScienceOptionalPackages {
    if(-not (Test-ScienceInteractiveConfiguration)){throw 'Optional package selection requires an interactive console.'}
    $path=Get-ScienceConfigurationPath
    Assert-ScienceRegularPath $path
    $original=[IO.File]::ReadAllBytes($path)
    $value=Assert-ScienceConfiguration (Read-ScienceJson $path)
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [Convert]::ToBase64String($original)){
        throw 'Configuration changed while reading; start again.'
    }
    $backend=Get-SciencePyTorchBackend $value.ScientificPackages
    $cudaAvailable=Test-ScienceNvidiaDevice
    Write-Host 'Optional packages'
    Write-Host ('Configured PyTorch backend: '+$backend.ToUpperInvariant())
    Write-Host ('NVIDIA CUDA device: '+$(if($cudaAvailable){'detected; compatibility will be checked by the solver'}else{'unavailable'}))
    Write-Host '1  PyTorch CPU'
    Write-Host '2  PyTorch NVIDIA CUDA'
    Write-Host 'R  Remove the PyTorch request'
    Write-Host 'Q  Back'
    while($true) {
        $choice=(Read-Host 'Optional packages').Trim().ToLowerInvariant()
        if(-not $choice -or $choice -eq 'q'){return $false}
        if($choice -eq '2' -and -not $cudaAvailable){
            Write-Host 'CUDA requires a working NVIDIA driver and a detectable GPU.'
            continue
        }
        if($choice -in @('1','2','r')){break}
        Write-Host 'Unknown selection.'
    }
    if($choice -eq 'r' -and (Read-Host 'Remove the configuration request only? [y/N]').Trim() -notmatch '^(?i:y|yes)$'){
        return $false
    }
    $selected=@{'1'='cpu';'2'='cuda';'r'='remove'}[$choice]
    $backup=Set-SciencePyTorchRequest -Choice $selected -Path $path -ExpectedBytes $original
    if($backup){Write-Host ('Previous package configuration saved to '+$backup)}
    if($selected -eq 'remove'){
        Write-Host 'PyTorch is no longer requested. Installed packages were preserved.'
        return $false
    }
    Write-Host ('PyTorch '+$selected.ToUpperInvariant()+' selected.')
    Write-Host 'Installation/update will follow now; no second menu selection is needed. Proposed package changes require separate approval.'
    return $true
}
