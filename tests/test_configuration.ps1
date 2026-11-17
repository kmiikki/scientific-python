[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'windows/science-integrity.ps1')
Assert-ScienceBundle (Join-Path $root 'windows')
. (Join-Path $root 'windows/science-config.ps1')
$work=Join-Path $TempRoot ('science-powershell-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$results=New-Object Collections.Generic.List[object]
function Assert-True {param([bool]$Value,[string]$Message='Assertion failed');if(-not $Value){throw $Message}}
function Expect-Failure {param([scriptblock]$Body);$failed=$false;try{$null=& $Body}catch{$failed=$true};Assert-True $failed 'Expected a safe rejection'}
function Test-Case {param([string]$Name,[scriptblock]$Body);try{$null=& $Body;$results.Add([pscustomobject]@{name=$Name;pass=$true});Write-Host "PASS $Name"}catch{$results.Add([pscustomobject]@{name=$Name;pass=$false;error=$_.Exception.Message});Write-Host "FAIL ${Name}: $($_.Exception.Message)"}}
function Put-Json {param([string]$Path,$Value);[void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path));[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 32),(New-Object Text.UTF8Encoding($false)))}
function Hash-File {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
$fixtures=Join-Path $root 'shared/fixtures'
try {
    foreach ($case in (Read-ScienceJson (Join-Path $fixtures 'configuration-cases.json'))) {
        Test-Case ('shared-'+$case.id) {
            $value=Get-ScienceDefaultConfiguration
            if ($case.changes) {foreach($p in $case.changes.PSObject.Properties){$value|Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force}}
            if ($case.append) {$value.ScientificPackages+=,$case.append}
            if ($case.remove) {$value.ScientificPackages=@($value.ScientificPackages|Where-Object {$_ -cne $case.remove})}
            $path=Join-Path $work 'input.json'
            $text=$value|ConvertTo-Json -Depth 32
            if (@($case.PSObject.Properties.Name) -ccontains 'raw') {$text=$case.raw}
            $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($text)
            if($case.bom){$bytes=[byte[]](0xef,0xbb,0xbf)+$bytes}
            if($case.hex){$bytes=[byte[]]@(0xff)}
            [IO.File]::WriteAllBytes($path,$bytes)
            if($case.valid){$null=Assert-ScienceConfiguration (Read-ScienceJson $path)}else{Expect-Failure {$null=Assert-ScienceConfiguration (Read-ScienceJson $path)}}
        }
    }
    Test-Case '42-approved-defaults-no-optionals' {
        $value=Get-ScienceDefaultConfiguration
        Assert-True ($value.ScientificPackages.Count -eq 42)
        $names=@($value.ScientificPackages|ForEach-Object {Get-ScienceSpecName $_})
        foreach($n in @('shap','pywavelets','optuna','plotly','hypothesis','polars','xgboost')){Assert-True ($names -ccontains $n)}
        foreach($n in @('pytorch','torchvision','lightgbm','pingouin','simplecv')){Assert-True ($names -cnotcontains $n)}
        Assert-True ($value.ScientificPackages -ccontains "ffmpeg[version='>=9.0.1,<10',build='gpl*']")
    }
    Test-Case 'windows-linux-scientific-selection-equivalence' {
        $common=Read-ScienceJson (Join-Path (Get-ScienceSharedDirectory) 'science-release.default.json')
        $windows=Get-ScienceDefaultConfiguration
        Assert-True ($common.ScientificPackages.Count -eq $windows.ScientificPackages.Count)
        for($i=0;$i -lt $common.ScientificPackages.Count;$i++) {
            if ((Get-ScienceSpecName $common.ScientificPackages[$i]) -ne 'ffmpeg') {
                Assert-True ($common.ScientificPackages[$i] -ceq $windows.ScientificPackages[$i])
            }
        }
    }
    Test-Case 'clean-windows-without-old-powershell' {
        $active=Join-Path $work 'clean/config/science-release.json'
        $value=Initialize-ScienceConfiguration -Path $active -Root (Join-Path $work 'clean/root')
        Assert-True ($value.ScientificPackages.Count -eq 42)
        Assert-True (Test-Path -LiteralPath $active)
    }
    Test-Case 'legacy-json-and-source-preserve-preferences-backup-repeat' {
        $dir=Join-Path $work 'legacy';[void][IO.Directory]::CreateDirectory($dir)
        $old=Join-Path $dir 'science-release.json';$source=Join-Path $dir 'science-release.ps1'
        $value=Read-ScienceJson (Join-Path $fixtures 'windows-legacy.json')
        $value|Add-Member -NotePropertyName Channels -NotePropertyValue @('conda-forge','my-lab')
        Put-Json $old $value
        $code=[IO.File]::ReadAllText((Join-Path $fixtures 'windows-legacy-release.ps1'))
        $code=$code.Replace("'seaborn';",'').Replace("'numpy'","'numpy>=2,<3'").Replace("'imageio-ffmpeg'","'imageio-ffmpeg'; 'pingouin'; `"pytorch[build='cpu*']`"")
        [IO.File]::WriteAllText($source,$code)
        $oldHash=Hash-File $old;$sourceHash=Hash-File $source
        $active=Join-Path $work 'migrated/config/science-release.json'
        $result=Initialize-ScienceConfiguration -Path $active -LegacyPath $old
        Assert-True ($result.ScientificPackages -ccontains 'numpy>=2,<3')
        Assert-True ($result.ScientificPackages -ccontains 'pingouin')
        Assert-True ($result.ScientificPackages -ccontains "pytorch[build='cpu*']")
        Assert-True ($result.ScientificPackages -cnotcontains 'seaborn')
        Assert-True ($result.ScientificPackages -cnotcontains 'polars')
        Assert-True ($result.Channels -ccontains 'my-lab')
        Assert-True ((Hash-File $old) -eq $oldHash);Assert-True ((Hash-File $source) -eq $sourceHash)
        $backup=@(Get-ChildItem -LiteralPath (Split-Path -Parent $active) -Filter 'science-release.legacy-*.json')
        Assert-True ($backup.Count -eq 1);Assert-True ((Hash-File $backup[0].FullName) -eq $oldHash)
        $hash=Hash-File $active;$time=[IO.File]::GetLastWriteTimeUtc($active)
        $again=Initialize-ScienceConfiguration -Path $active -LegacyPath $old
        Assert-True ((Hash-File $active) -eq $hash);Assert-True ([IO.File]::GetLastWriteTimeUtc($active) -eq $time)
        Remove-Item -LiteralPath $old
        $again=Initialize-ScienceConfiguration -Path $active -LegacyPath $old
        Assert-True ((Hash-File $active) -eq $hash);Assert-True ([IO.File]::GetLastWriteTimeUtc($active) -eq $time)
    }
    Test-Case 'missing-legacy-powershell-blocks-without-any-change' {
        $dir=Join-Path $work 'missing-source';[void][IO.Directory]::CreateDirectory($dir)
        $old=Join-Path $dir 'science-release.json';Copy-Item (Join-Path $fixtures 'windows-legacy.json') $old
        $rootDir=Join-Path $dir 'root';$envDir=Join-Path $rootDir 'envs/science';[void][IO.Directory]::CreateDirectory($envDir)
        $sentinel=Join-Path $envDir 'KEEP';[IO.File]::WriteAllText($sentinel,'unchanged')
        $oldHash=Hash-File $old;$envHash=Hash-File $sentinel;$active=Join-Path $dir 'config/science-release.json'
        Expect-Failure {Initialize-ScienceConfiguration -Path $active -Root $rootDir -LegacyPath $old}
        Assert-True ((Hash-File $old) -eq $oldHash);Assert-True ((Hash-File $sentinel) -eq $envHash)
        Assert-True (-not (Test-Path -LiteralPath $active));Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $active)))
    }
    Test-Case 'existing-environment-no-config-is-not-clean' {
        $rootDir=Join-Path $work 'no-config/root';$envDir=Join-Path $rootDir 'envs/science';[void][IO.Directory]::CreateDirectory($envDir)
        $sentinel=Join-Path $envDir 'KEEP';[IO.File]::WriteAllText($sentinel,'unchanged');$hash=Hash-File $sentinel
        $active=Join-Path $work 'no-config/config/science-release.json'
        Expect-Failure {Initialize-ScienceConfiguration -Path $active -Root $rootDir}
        Assert-True (-not (Test-Path -LiteralPath $active));Assert-True ((Hash-File $sentinel) -eq $hash)
    }
    Test-Case 'another-targets-default-does-not-authorize-unknown-old-environment' {
        $active=Join-Path $work 'other-target/config/science-release.json'
        $null=Initialize-ScienceConfiguration -Path $active -Root (Join-Path $work 'other-target/clean')
        $hash=Hash-File $active
        $oldRoot=Join-Path $work 'other-target/unknown';[void][IO.Directory]::CreateDirectory((Join-Path $oldRoot 'envs/science'))
        $marker=Join-Path $oldRoot 'envs/science/KEEP';[IO.File]::WriteAllText($marker,'keep');$markerHash=Hash-File $marker
        Expect-Failure {Initialize-ScienceConfiguration -Path $active -Root $oldRoot}
        Assert-True ((Hash-File $active) -eq $hash);Assert-True ((Hash-File $marker) -eq $markerHash)
    }
    Test-Case 'dynamic-legacy-source-is-never-executed' {
        $dir=Join-Path $work 'dynamic';[void][IO.Directory]::CreateDirectory($dir)
        $old=Join-Path $dir 'science-release.json';Copy-Item (Join-Path $fixtures 'windows-legacy.json') $old
        [IO.File]::WriteAllText((Join-Path $dir 'science-release.ps1'),'function Get-SciencePackageSpecs { @( (throw "must not execute") ) }')
        Expect-Failure {Initialize-ScienceConfiguration -Path (Join-Path $dir 'active/science-release.json') -LegacyPath $old}
    }
    Test-Case 'new-source-does-not-overwrite-active-user-config' {
        $active=Join-Path $work 'preserve/science-release.json';$v=Initialize-ScienceConfiguration -Path $active
        $v.ScientificPackages=@($v.ScientificPackages|Where-Object {$_ -cne 'seaborn'})+@('pingouin')
        Put-Json $active $v;$before=Hash-File $active
        $v=Initialize-ScienceConfiguration -Path $active
        Assert-True ((Hash-File $active) -eq $before)
        Assert-ScienceBundle (Join-Path $root 'windows')
    }
    Test-Case 'immutable-script-schema-and-policy-modifications-detected' {
        $copy=Join-Path $work 'tamper';[void][IO.Directory]::CreateDirectory($copy)
        Copy-Item (Join-Path $root 'windows') (Join-Path $copy 'windows') -Recurse
        Copy-Item (Join-Path $root 'shared') (Join-Path $copy 'shared') -Recurse
        foreach($relative in @('windows/science-update.ps1','shared/science-release.schema.json','windows/science-installer-release.json')) {
            $path=Join-Path $copy $relative;$bytes=[IO.File]::ReadAllBytes($path)
            [IO.File]::WriteAllBytes($path,($bytes+[byte[]]@(32)))
            Expect-Failure {Assert-ScienceBundle (Join-Path $copy 'windows')}
            [IO.File]::WriteAllBytes($path,$bytes)
        }
        Assert-ScienceBundle (Join-Path $copy 'windows')
    }
    Test-Case 'configured-channels-only' {
        $v=Get-ScienceDefaultConfiguration;$v.Channels=@('conda-forge','my-lab')
        $args=Get-ScienceChannelArguments $v
        Assert-True ($args -contains '--override-channels');Assert-True ($args -contains '--no-rc')
        Assert-True (($args|Where-Object {$_ -eq '-c'}).Count -eq 2)
    }
    Test-Case 'all-powershell-files-parse' {
        foreach($path in Get-ChildItem (Join-Path $root 'windows') -Filter '*.ps1' -Recurse) {
            $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($path.FullName,[ref]$tokens,[ref]$errors)
            Assert-True ($errors.Count -eq 0) ($path.Name+': '+($errors.Message -join '; '))
        }
    }
    Test-Case 'entry-error-preferences-and-helper-functions-are-real-statements' {
        foreach($name in @('01-prepare-windows.ps1','02-install-science.ps1','04-remove-science.ps1','05-remove-micromamba.ps1','patch-opencl.ps1','spyder-launcher.ps1')) {
            $path=Join-Path (Join-Path $root 'windows') $name
            $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
            $assignments=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$ErrorActionPreference'},$false))
            Assert-True ($assignments.Count -ge 1) ('No actual error-preference assignment: '+$name)
            Assert-True (-not [IO.File]::ReadAllText($path).TrimStart([char]0xfeff).Contains([string][char]0xfeff)) 'Embedded BOM changes a command name'
        }
        . (Join-Path $root 'windows/science-launcher-common.ps1')
        Assert-True ((ConvertTo-ScienceWindowsArgument 'C:\path with spaces\') -ceq '"C:\path with spaces\\"')
    }
    Test-Case 'windows-effective-package-getter-uses-only-user-list' {
        $oldLocal=$env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA=Join-Path $work 'authoritative'
            $v=Initialize-ScienceConfiguration
            $v.ScientificPackages=@($v.ScientificPackages|Where-Object {$_ -cne 'seaborn'})+@('pingouin')
            Put-Json (Get-ScienceConfigurationPath) $v
            . (Join-Path $root 'windows/science-release.ps1')
            $specs=@(Get-SciencePackageSpecs)
            Assert-True ($specs -cnotcontains 'seaborn')
            Assert-True ($specs -ccontains 'pingouin')
            Assert-True ($specs.Count -eq 42)
        } finally {$env:LOCALAPPDATA=$oldLocal}
    }
    Test-Case 'windows-package-commit-requires-verified-layout' {
        $script:ScienceRelease=Read-ScienceJson (Join-Path $root 'windows/science-installer-release.json')
        . (Join-Path $root 'windows/science-update.ps1')
        Expect-Failure {Invoke-ScienceEnvironmentSync -Layout $null -Packages (Get-SciencePackageSpecs)}
    }

    foreach($case in (Read-ScienceJson (Join-Path $fixtures 'release-upgrade-cases.json'))) {
        Test-Case ('release-upgrade-'+$case.id) {
            $value=Get-ScienceDefaultConfiguration
            $value.ScientificPackages=@($value.ScientificPackages|Where-Object {@($case.remove) -cnotcontains (Get-ScienceSpecName $_)}|ForEach-Object {
                $name=Get-ScienceSpecName $_
                if($case.replace -and $case.replace.$name){$case.replace.$name}else{$_}
            })+@($case.append|Where-Object {$null -ne $_})
            if($case.channels){$value.Channels=@($case.channels)}
            $path=Join-Path $work ('upgrade-'+$case.id+'/science-release.json');Put-Json $path $value
            $before=Hash-File $path;$time=[IO.File]::GetLastWriteTimeUtc($path)
            $missing=@(Get-ScienceMissingReleasePackages $value|ForEach-Object {Get-ScienceSpecName $_})
            Assert-True (($missing -join '|') -ceq (@($case.missing) -join '|'))
            $context=@{Calls=0}
            $review={param($prompt);$context.Calls++;return $case.answer}.GetNewClosure()
            $result=Update-ScienceReleasePackages -Path $path -Interactive $case.interactive -Reviewer $review
            Assert-True (($result.Channels -join '|') -ceq ($value.Channels -join '|'))
            Assert-True (($result.ScientificPackages -join '|') -ceq ((@($value.ScientificPackages)+@($case.added)) -join '|'))
            Assert-True (($context.Calls -gt 0) -eq ($case.missing.Count -gt 0 -and $case.interactive))
            if(-not $case.added.Count){Assert-True ((Hash-File $path) -eq $before);Assert-True ([IO.File]::GetLastWriteTimeUtc($path) -eq $time)}
            else {
                $before=Hash-File $path;$time=[IO.File]::GetLastWriteTimeUtc($path)
                $again=Update-ScienceReleasePackages -Path $path -Interactive $true -Reviewer {throw 'Unexpected second prompt'}
                Assert-True ((Hash-File $path) -eq $before);Assert-True ([IO.File]::GetLastWriteTimeUtc($path) -eq $time)
            }
            Assert-True (@(Get-ChildItem (Split-Path -Parent $path) -Filter '.science-config-*').Count -eq 0)
            Assert-True (@(Get-ChildItem (Split-Path -Parent $path) -Filter 'science-release.legacy-*').Count -eq 0)
        }
    }
    Test-Case 'release-upgrade-invalid-config-no-prompt-or-replacement' {
        $path=Join-Path $work 'invalid-upgrade/science-release.json';Put-Json $path (Get-ScienceDefaultConfiguration)
        [IO.File]::WriteAllText($path,'{bad}');$before=Hash-File $path
        Expect-Failure {Update-ScienceReleasePackages -Path $path -Interactive $true -Reviewer {throw 'Must not prompt'}}
        Assert-True ((Hash-File $path) -eq $before)
    }
    Test-Case 'release-upgrade-concurrent-edit-is-preserved' {
        $value=Get-ScienceDefaultConfiguration;$value.ScientificPackages=@($value.ScientificPackages|Where-Object {$_ -cne 'optuna'})
        $path=Join-Path $work 'concurrent-upgrade/science-release.json';Put-Json $path $value
        $context=@{Hash=''}
        $review={param($prompt);$value.Channels=@('other-lab');Put-Json $path $value;$context.Hash=Hash-File $path;return 'yes'}.GetNewClosure()
        Expect-Failure {Update-ScienceReleasePackages -Path $path -Interactive $true -Reviewer $review}
        Assert-True ((Hash-File $path) -eq $context.Hash)
        Assert-True (@(Get-ChildItem (Split-Path -Parent $path) -Filter '.science-config-*').Count -eq 0)
    }
    Test-Case 'release-upgrade-staged-write-abort-preserves-original' {
        $path=Join-Path $work 'abort-upgrade/science-release.json';Put-Json $path (Get-ScienceDefaultConfiguration);$before=Hash-File $path
        Expect-Failure {Set-ScienceConfigBytes -Path $path -Bytes ([Text.Encoding]::UTF8.GetBytes('new')) -ExpectedBytes ([Text.Encoding]::UTF8.GetBytes('wrong original'))}
        Assert-True ((Hash-File $path) -eq $before)
        Assert-True (@(Get-ChildItem (Split-Path -Parent $path) -Filter '.science-config-*').Count -eq 0)
    }
    Test-Case 'release-upgrade-result-is-validated-before-write' {
        $path=Join-Path $work 'invalid-result/science-release.json';$value=Get-ScienceDefaultConfiguration
        $value.ScientificPackages=@($value.ScientificPackages|Where-Object {$_ -cne 'shap'});Put-Json $path $value;$before=Hash-File $path
        $definition=(Get-Command Get-ScienceDefaultConfiguration).ScriptBlock
        try {
            function Get-ScienceDefaultConfiguration {return [pscustomobject]@{SchemaVersion=1;Channels=@('new-channel');ScientificPackages=@('new-channel::shap')}}
            Expect-Failure {Update-ScienceReleasePackages -Path $path -Interactive $true -Reviewer {'yes'}}
            Assert-True ((Hash-File $path) -eq $before)
        } finally {Set-Item Function:Get-ScienceDefaultConfiguration $definition}
    }
    Test-Case 'release-upgrade-preserves-synthetic-environments' {
        $path=Join-Path $work 'scope-upgrade/science-release.json';$value=Get-ScienceDefaultConfiguration
        $value.ScientificPackages=@($value.ScientificPackages|Where-Object {$_ -cne 'shap'});Put-Json $path $value
        $markers=@()
        foreach($name in @('science','py314-opencv5-cuda')){$marker=Join-Path $work ('scope-upgrade/root/envs/'+$name+'/KEEP');[void][IO.Directory]::CreateDirectory((Split-Path -Parent $marker));[IO.File]::WriteAllText($marker,'unchanged');$markers+=,$marker}
        $null=Update-ScienceReleasePackages -Path $path -Interactive $true -Reviewer {'yes'}
        foreach($marker in $markers){Assert-True ([IO.File]::ReadAllText($marker) -ceq 'unchanged')}
    }
    Test-Case 'release-upgrade-effective-getter-reaches-updated-requests' {
        $previousLocal=$env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA=Join-Path $work 'upgrade-getter'
            $path=Get-ScienceConfigurationPath;$value=Initialize-ScienceConfiguration
            $seven=@('shap','pywavelets','optuna','plotly','hypothesis','polars','xgboost')
            $value.ScientificPackages=@($value.ScientificPackages|Where-Object {$seven -cnotcontains (Get-ScienceSpecName $_)});Put-Json $path $value
            $null=Update-ScienceReleasePackages -Interactive $true -Reviewer {'yes'}
            . (Join-Path $root 'windows/science-release.ps1')
            $specs=@(Get-SciencePackageSpecs)
            foreach($name in $seven){Assert-True ($specs -ccontains $name)}
            Assert-True ($specs.Count -eq 42)
        }finally{$env:LOCALAPPDATA=$previousLocal}
    }
    Test-Case 'release-upgrade-noninteractive-terminal-detection' {
        Assert-True (-not (Test-ScienceInteractiveConfiguration)) 'Redirected test input/output must not prompt'
    }
    $failed=@($results|Where-Object {-not $_.pass})
    Write-Host ("RESULT tests="+$results.Count+" passed="+($results.Count-$failed.Count)+" failed="+$failed.Count)
    if($failed.Count){exit 1}
} finally {Remove-Item -LiteralPath $work -Recurse -Force}
