[CmdletBinding()]
param([string]$TempRoot=[IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $TempRoot ('science-optional-tests-'+[Guid]::NewGuid().ToString('N'))
$previousLocalAppData=$env:LOCALAPPDATA
$env:LOCALAPPDATA=Join-Path $work 'local'
[void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
. (Join-Path $root 'windows/science-release.ps1')
. (Join-Path $root 'windows/science-update.ps1')

$fixture=@{Answers=$null;Cuda=$false;Interactive=$true;Steps=@();Passed=0}
function Test-ScienceInteractiveConfiguration {return $fixture.Interactive}
function Test-ScienceNvidiaDevice {
    $fixture.Events.Add('probe')
    return $fixture.Cuda
}
function Read-Host {
    $answer=$fixture.Answers.Dequeue()
    $fixture.Events.Add("choice:$answer")
    return $answer
}
function Check {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw $Message}
}
function Reject {
    param([scriptblock]$Operation,[string]$Pattern)
    $message=''
    try {$null=& $Operation}catch{$message=$_.Exception.Message}
    Check ($message -match $Pattern) "Expected a rejection matching '$Pattern'; received '$message'."
}
function Put-Json {
    param([string]$Path,$Value)
    Set-ScienceConfigBytes $Path ([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 16)))
}
function Answers {
    param([string[]]$Value)
    $fixture.Answers=New-Object 'Collections.Generic.Queue[string]'
    foreach($answer in $Value){$fixture.Answers.Enqueue($answer)}
}
function Case {
    param([string]$Name,[scriptblock]$Body)
    $fixture.Cuda=$false
    $fixture.Events=New-Object 'Collections.Generic.List[string]'
    $fixture.Interactive=$true
    Put-Json $path (Get-ScienceDefaultConfiguration)
    & $Body
    $fixture.Passed++
    Write-Host "PASS $Name"
}
try {
    $path=Get-ScienceConfigurationPath
    Case 'cpu-selection-saves-exact-backup-and-repeat-is-noop' {
        $before=Get-ScienceFileSha256 $path
        $value=Read-ScienceJson $path
        Answers @('1')
        Check (Select-ScienceOptionalPackages) 'CPU selection did not continue to install.'
        $withCpu=Read-ScienceJson $path
        Check ($withCpu.ScientificPackages[-1] -ceq "pytorch[build='cpu*']") 'CPU build constraint is missing.'
        Check (($withCpu.ScientificPackages[0..($value.ScientificPackages.Count-1)] -join '|') -ceq ($value.ScientificPackages -join '|')) 'Other requests changed.'
        $backup=Join-Path (Split-Path -Parent $path) "science-release.optional-$before.json"
        Check ((Get-ScienceFileSha256 $backup) -ceq $before) 'Backup differs from the original configuration.'
        $timestamp=[IO.File]::GetLastWriteTimeUtc($path)
        Answers @('1')
        Check (Select-ScienceOptionalPackages) 'Repeated CPU selection did not continue.'
        Check ([IO.File]::GetLastWriteTimeUtc($path) -eq $timestamp) 'Repeated CPU selection rewrote configuration.'
    }
    Case 'fresh-menu-probes-only-after-cuda-selection' {
        $fixture.Cuda=$true
        foreach($selection in @('', '0', '1', '2')){
            Put-Json $path (Get-ScienceDefaultConfiguration)
            $fixture.Events.Clear()
            Answers @($selection)
            $output=Select-ScienceOptionalPackages -Fresh 6>&1
            Check ($output[-1] -eq $true) 'Fresh option did not proceed to installation.'
            $label=switch($selection){'1'{'PyTorch CPU selected.'} '2'{'PyTorch CUDA selected.'} default{'No PyTorch selected.'}}
            Check ($output[-2].ToString() -ceq $label) 'The selection confirmation was not the last message.'
            $messages=(@($output) -join "`n")
            Check ($messages -match '0  No PyTorch \(default\)') 'Fresh menu omitted the default.'
            $expected=switch($selection){'1'{'cpu'} '2'{'cuda'} default{'none'}}
            Check ((Get-SciencePyTorchBackend (Read-ScienceJson $path).ScientificPackages) -ceq $expected) 'Saved backend differs from the choice.'
            if($selection -eq '2'){
                Check (($fixture.Events -join '|') -ceq 'choice:2|probe') 'CUDA detection did not follow selection.'
                Check ($messages -match 'NVIDIA CUDA device detected') 'CUDA detection result was not shown.'
            }else{
                Check ($fixture.Events.Count -eq 1) 'No PyTorch or CPU ran GPU detection.'
                Check ($messages -notmatch 'NVIDIA CUDA device|working NVIDIA driver') 'A non-CUDA choice displayed a detection message.'
            }
        }
    }
    Case 'fresh-root-ignores-old-snapshot-and-existing-prefix-can-recover-it' {
        $target=Join-Path $work 'snapshot-root'
        [void][IO.Directory]::CreateDirectory($target)
        $value=Get-ScienceDefaultConfiguration
        $value.ScientificPackages+=@("pytorch[build='cuda*']")
        $snapshot=Join-Path $target 'science-release.json'
        Put-Json $snapshot $value
        $saved=Join-Path $work 'snapshot-active.json'
        $fresh=Initialize-ScienceConfiguration -Path $saved -Root $target
        Check ((Get-SciencePyTorchBackend $fresh.ScientificPackages) -ceq 'none') 'Fresh root restored CUDA from an old snapshot.'
        Check ((Get-SciencePyTorchBackend (Read-ScienceJson $snapshot).ScientificPackages) -ceq 'cuda') 'Old snapshot was overwritten.'
        [void][IO.Directory]::CreateDirectory((Join-Path $target 'envs/science'))
        $recovered=Initialize-ScienceConfiguration -Path (Join-Path $work 'snapshot-recovered.json') -Root $target
        Check ((Get-SciencePyTorchBackend $recovered.ScientificPackages) -ceq 'cuda') 'Existing prefix lost its saved request.'
    }
    Case 'cuda-switch-preserves-version-channel-and-other-requests' {
        $value=Read-ScienceJson $path
        $value.Channels+=@('my-lab')
        $value.ScientificPackages+=@('my-lab::package=1','conda-forge::pytorch>=2.13,<=2.14','torchvision')
        Put-Json $path $value
        Answers @('1')
        Check (Select-ScienceOptionalPackages) 'CPU selection failed.'
        $fixture.Cuda=$true
        Answers @('2')
        Check (Select-ScienceOptionalPackages) 'CUDA selection failed.'
        $after=Read-ScienceJson $path
        Check (($after.Channels -join '|') -ceq ($value.Channels -join '|')) 'Channels changed.'
        Check ($after.ScientificPackages[-2] -ceq "conda-forge::pytorch>=2.13,<=2.14[build='cuda*']") 'PyTorch version constraint changed.'
        Check ($after.ScientificPackages[-1] -ceq 'torchvision') 'Other optional request changed.'
        Check ((Get-SciencePyTorchBackend $after.ScientificPackages) -ceq 'cuda') 'Selected CUDA backend was not detected.'
    }
    Case 'unavailable-cuda-back-and-noninteractive-preserve-the-configuration' {
        $before=Get-ScienceFileSha256 $path
        Answers @('2','q')
        Check (-not (Select-ScienceOptionalPackages)) 'Unavailable CUDA entered install.'
        $fixture.Interactive=$false
        Reject {Select-ScienceOptionalPackages} 'interactive console'
        Check ((Get-ScienceFileSha256 $path) -ceq $before) 'Unavailable CUDA or redirected input changed configuration.'
    }
    Case 'remove-request-only-with-confirmation' {
        $value=Read-ScienceJson $path
        $value.ScientificPackages+=@("pytorch[build='cpu*']", 'torchvision=1')
        Put-Json $path $value
        $before=Get-ScienceFileSha256 $path
        Answers @('r','')
        Check (-not (Select-ScienceOptionalPackages)) 'Removal decline entered install.'
        Check ((Get-ScienceFileSha256 $path) -ceq $before) 'Declined removal changed configuration.'
        Answers @('r','y')
        Check (-not (Select-ScienceOptionalPackages)) 'Configuration removal entered install.'
        $after=Read-ScienceJson $path
        Check ((Get-SciencePyTorchBackend $after.ScientificPackages) -ceq 'none') 'PyTorch request remains.'
        Check ($after.ScientificPackages[-1] -ceq 'torchvision=1') 'Torchvision request changed.'
    }
    Case 'pinned-build-and-stale-configuration-are-preserved' {
        $value=Read-ScienceJson $path
        $value.ScientificPackages+=@("pytorch[version='2.13.0',build='cpu_mkl_py314_0']")
        Put-Json $path $value
        $before=Get-ScienceFileSha256 $path
        $fixture.Cuda=$true
        Answers @('2')
        Reject {Select-ScienceOptionalPackages} 'explicit build constraint'
        Reject {Set-SciencePyTorchRequest -Choice cpu -ExpectedBytes ([byte[]]@(1,2,3))} 'changed during review'
        Check ((Get-ScienceFileSha256 $path) -ceq $before) 'Pinned or stale requests were overwritten.'
    }
    Case 'new-root-reset-preserves-shared-config-and-backs-up-on-explicit-reset' {
        $target=Join-Path $work 'new-reset-root'
        $old=Join-Path $work 'other-config-root'
        $layout=[pscustomobject]@{Root=$target;Science=(Join-Path $target 'envs/science')}
        $value=Read-ScienceJson $path
        $value.ScientificPackages+=@("pytorch[build='cpu*']")
        Put-Json $path $value
        $before=Get-ScienceFileSha256 $path
        function Get-ScienceLayoutStatuses {return @()}
        Set-ScienceConfigurationOrigin $path $old
        $receipt=(Get-ScienceConfigurationOrigins $path $target).Path
        Answers @()
        Show-ScienceNewRootConfiguration $layout $path
        Check ((Get-ScienceFileSha256 $path) -ceq $before) 'A configuration used by another root was reset.'
        Remove-Item -LiteralPath $receipt
        Answers @('')
        Show-ScienceNewRootConfiguration $layout $path
        Check ((Get-ScienceFileSha256 $path) -ceq $before) 'Default answer did not preserve the saved configuration.'
        Answers @('yes')
        Show-ScienceNewRootConfiguration $layout $path
        Check ((Get-SciencePyTorchBackend (Read-ScienceJson $path).ScientificPackages) -ceq 'none') 'Reset did not remove saved optional requests.'
        $backup=Join-Path (Split-Path -Parent $path) "science-release.pre-reset-$before.json"
        Check ((Get-ScienceFileSha256 $backup) -ceq $before) 'Reset backup did not preserve exact bytes.'
    }
    Case 'normal-menu-dispatches-optional-packages-and-camera-independently' {
        $menu=Join-Path $root 'windows/00-menu.ps1'
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($menu,[ref]$tokens,[ref]$errors)
        Check (-not $errors.Count) 'Menu did not parse.'
        $dispatch=$ast.Find({param($node) $node -is [Management.Automation.Language.SwitchStatementAst]},$true)
        $stepper=[scriptblock]::Create('foreach($iteration in @(1)) {'+[Environment]::NewLine+$dispatch.Extent.Text+[Environment]::NewLine+'}')
        $target=Join-Path $work 'menu-mamba'
        $layout=[pscustomobject]@{Mode='Home';Root=$target;Science=(Join-Path $target 'envs/science')}
        function Select-ScienceInstallLayout {return $layout}
        function Initialize-ScienceConfiguration {}
        function Show-ScienceNewRootConfiguration {}
        function Show-OtherInstallationSummary {}
        function Pause-Menu {}
        function Invoke-Step {
            param($ScriptName,$ExtraCommand,$AllowedExitCode)
            $fixture.Steps+=("$ScriptName $ExtraCommand")
            if ($ScriptName -eq '07-usb-camera-test.ps1') {return $AllowedExitCode}
            return 0
        }
        $Mode='Auto'
        $choice='1'
        $fixture.Steps=@()
        Answers @('')
        & $stepper
        Check ($fixture.Answers.Count -eq 0 -and $fixture.Steps.Count -eq 2 -and
            $fixture.Steps[1] -match '02-install-science.ps1.*-PyTorchSelectionReviewed') 'Install option 1 did not review fresh PyTorch selection.'
        Check ($fixture.Steps[1] -notmatch '-SkipReleaseDefaultOffer') 'Option 1 skipped release request review.'
        [void][IO.Directory]::CreateDirectory($layout.Science)
        $fixture.Steps=@()
        Answers @()
        & $stepper
        Check ($fixture.Steps.Count -eq 2 -and $fixture.Steps[1] -notmatch '-PyTorchSelectionReviewed') 'Normal update unexpectedly prompted for a backend.'
        $choice='O'
        $fixture.Steps=@()
        Answers @('1')
        & $stepper
        Check ($fixture.Steps.Count -eq 2) 'Optional CPU selection did not run the standard installer.'
        Check ($fixture.Steps[0] -match '01-prepare-windows.ps1' -and $fixture.Steps[1] -match '02-install-science.ps1.*-SkipReleaseDefaultOffer') 'Optional selection bypassed the standard installer.'
        $fixture.Steps=@()
        Answers @('r','y')
        & $stepper
        Check (-not $fixture.Steps.Count) 'Removing the request launched the installer.'
        $choice='U'
        $Mode='Safe'
        & $stepper
        Check ($fixture.Steps.Count -eq 1 -and $fixture.Steps[0] -ceq "07-usb-camera-test.ps1 -Mode 'Safe'") 'Camera test bypassed its standalone launcher or invoked another workflow.'
    }
    Case 'solver-rejects-opposite-build-before-approval' {
        $packages=@('python','python_abi','spyder','apache-arrow-proc','opencv','ffmpeg',"pytorch[build='cpu*']")
        $before=@{
            'python'=@{version='3.14.10'}; 'python_abi'=@{build='0_cp314'}
            'spyder'=@{version='6.1.8'}; 'apache-arrow-proc'=@{build='cpu'}
            'opencv'=@{version='5.1.0';build='qt6_test'}; 'ffmpeg'=@{version='9.0.2';build='gpl_test'}
        }
        $plan=[pscustomobject]@{success=$true;actions=@{LINK=@(@{name='pytorch';build='cuda129_mkl_py314_0'})}}
        $floors=@{opencv='5.1.0';ffmpeg='9.0.1'}
        Reject {Assert-SciencePlan $plan $before $floors $packages} 'requested PyTorch backend'
        $plan.actions.LINK[0].build='cpu_mkl_py314_0'
        Check ((Assert-SciencePlan $plan $before $floors $packages)['pytorch'].build -ceq 'cpu_mkl_py314_0') 'Valid CPU build rejected.'
    }

    Case 'fresh-solver-keeps-no-pytorch-and-cpu-off-the-cuda-path' {
        $target=Join-Path $work 'fresh-plan-root'
        [void][IO.Directory]::CreateDirectory($target)
        $layout=[pscustomobject]@{
            Root=$target;Science=(Join-Path $target 'envs/science');Pkgs=(Join-Path $target 'pkgs')
            Tmp=(Join-Path $target 'tmp');Micromamba=(Join-Path $target 'inert-micromamba')
        }
        [IO.File]::WriteAllText($layout.Micromamba,'Inert test data')
        $policy=Get-ScienceEffectiveRelease
        $foundation=@('python','python_abi','spyder','apache-arrow-proc','opencv','ffmpeg')
        $policy.ScientificPackages=$foundation
        $policy.MicromambaSha256=Get-ScienceFileSha256 $layout.Micromamba
        $script:ScienceRelease=$policy
        $rows=@(
            @{name='python';version='3.14.10';build='test'}, @{name='python_abi';version='3.14';build='0_cp314'}
            @{name='spyder';version='6.1.8';build='test'}, @{name='apache-arrow-proc';version='20.0.0';build='cpu'}
            @{name='opencv';version='5.1.0';build='qt6_test'}, @{name='ffmpeg';version='9.0.2';build='gpl_test'}
        )
        $plan=[pscustomobject]@{success=$true;actions=@{LINK=$rows}}
        $calls=@{Hardware=0;Solves=0;Reviews=0}
        function Get-ScienceEffectiveRelease {return $policy}
        function Assert-ScienceNotInUse {}
        function Get-ScienceNvidiaCudaHardware {$calls.Hardware++;throw 'Unexpected CUDA hardware detection.'}
        function Invoke-ScienceMambaJson {
            param($Layout,$Arguments,$CudaOverrides,$CudaRetryArguments)
            Check ($Arguments[0] -ceq 'create' -and $Arguments -ccontains '--dry-run') 'Fresh solver did not stay in dry run.'
            Check (-not $CudaOverrides -and -not $CudaRetryArguments) 'Non-CUDA solve received CUDA settings.'
            Check (@($Arguments | Where-Object {$_ -clike 'pytorch*'}).Count -eq ($policy.ScientificPackages.Count-$foundation.Count)) 'Unexpected PyTorch request.'
            $calls.Solves++
            return $plan
        }
        function Invoke-ScienceReviewedTransaction {$calls.Reviews++;throw 'Stopped at approval.'}
        $gpu=@{name='pytorch';version='2.13.0';build='cuda129_test'}
        $plan.actions.LINK=$rows+@($gpu)
        Reject {Invoke-ScienceEnvironmentSync $layout $policy.ScientificPackages} 'includes PyTorch as a dependency'
        Check ($calls.Reviews -eq 0) 'Unselected PyTorch reached approval.'
        $plan.actions.LINK=$rows
        Reject {Invoke-ScienceEnvironmentSync $layout $policy.ScientificPackages} 'Stopped at approval'
        $policy.ScientificPackages=$foundation+@("pytorch[build='cpu*']")
        $cpu=@{name='pytorch';version='2.13.0';build='cpu_mkl_test'}
        $plan.actions.LINK=$rows+@($cpu)
        Reject {Invoke-ScienceEnvironmentSync $layout $policy.ScientificPackages} 'Stopped at approval'
        Check ($calls.Solves -eq 3 -and $calls.Reviews -eq 2 -and $calls.Hardware -eq 0) 'Fresh non-CUDA checks were inconsistent.'
        Check (-not (Test-Path -LiteralPath $layout.Science)) 'Dry run changed the target.'
    }
    Case 'unchanged-cpu-plan-does-not-request-package-approval' {
        Answers @('1')
        Check (Select-ScienceOptionalPackages) 'CPU selection did not continue.'
        $mamba=Join-Path $work 'current-root'
        $prefix=Join-Path $mamba 'envs/science'
        $meta=Join-Path $prefix 'conda-meta'
        [void][IO.Directory]::CreateDirectory($meta)
        $layout=[pscustomobject]@{
            Root=$mamba; Science=$prefix; Pkgs=(Join-Path $mamba 'pkgs')
            Tmp=(Join-Path $mamba 'tmp'); Micromamba=(Join-Path $mamba 'fake-native')
        }
        [IO.File]::WriteAllText($layout.Micromamba,'Inert test data')
        $policy=Get-ScienceEffectiveRelease
        $policy.ScientificPackages=@('python','python_abi','spyder','apache-arrow-proc','opencv','ffmpeg',"pytorch[build='cpu*']")
        $policy.MicromambaSha256=Get-ScienceFileSha256 $layout.Micromamba
        $rows=@(
            @('python','3.14.10','0'), @('python_abi','3.14','0_cp314'), @('spyder','6.1.8','0'),
            @('apache-arrow-proc','20.0.0','cpu'), @('opencv','5.1.0','qt6_test'), @('ffmpeg','9.0.2','gpl_test'),
            @('pytorch','2.13.0','cpu_mkl_py314_0')
        )
        foreach($row in $rows){
            $name,$version,$build=$row
            $filename="$name-$version-$build.conda"
            Put-Json (Join-Path $meta ($name+'.json')) @{
                name=$name; version=$version; build=$build; subdir='win-64'
                sha256=('a'*64); url="https://conda.anaconda.org/conda-forge/win-64/$filename"; fn=$filename
            }
        }
        $before=Get-SciencePrefixDigest $prefix
        $script:ScienceRelease=$policy
        $calls=@{Native=0;Hardware=0}
        function Get-ScienceNvidiaCudaHardware {
            $calls.Hardware++
            return [pscustomobject]@{Driver='13.2';Architecture='12.0';DriverRelease='595.99.02'}
        }
        function Get-ScienceEffectiveRelease {return $policy}
        function Assert-ScienceNotInUse {}
        function Confirm-ScienceTransaction {throw 'No-op must not request package approval.'}
        function Invoke-ScienceNative {
            param($Executable,$Arguments,$Environment)
            $calls.Native++
            Check ($Arguments[0] -ceq 'update' -and $Arguments -ccontains '--dry-run' -and
                   $Arguments -ccontains "pytorch[build='cpu*']") 'Unexpected native command.'
            return @{ExitCode=0;Stdout='{"success":true}';Stderr=''}
        }
        Invoke-ScienceEnvironmentSync $layout $policy.ScientificPackages
        Check ($calls.Native -eq 1 -and $calls.Hardware -eq 0) 'CPU no-op ran hardware detection or another native command.'
        Check ((Get-SciencePrefixDigest $prefix) -ceq $before) 'No-op rewrote package metadata.'

        Answers @('2')
        $fixture.Cuda=$true
        Check (Select-ScienceOptionalPackages) 'CUDA selection did not continue.'
        $policy.ScientificPackages[-1]="pytorch[build='cuda*']"
        function Invoke-ScienceNative {
            param($Executable,$Arguments,$Environment)
            $calls.Native++
            Check ($Arguments[0] -ceq 'info') 'A solver started without a detected CUDA virtual package.'
            return @{ExitCode=0;Stdout='{"virtual packages": ["__win=0=0"]}';Stderr=''}
        }
        Reject {Invoke-ScienceEnvironmentSync $layout $policy.ScientificPackages} 'could not verify the NVIDIA driver'
        Check ((Get-SciencePrefixDigest $prefix) -ceq $before) 'Unsupported CUDA rewrote metadata.'

        function Invoke-ScienceNative {
            param($Executable,$Arguments,$Environment)
            if($Arguments[0] -ceq 'info'){
                return @{ExitCode=0;Stdout='{"virtual packages":["__cuda=13.2=0"]}';Stderr=''}
            }
            Check ($Arguments -ccontains '--dry-run') 'An incompatible CUDA plan reached mutation.'
            return @{ExitCode=1;Stdout='{"solver_problems":["nothing provides __cuda_arch"]}';Stderr=''}
        }
        Reject {Invoke-ScienceEnvironmentSync $layout $policy.ScientificPackages} '__cuda_arch'
        Check ($calls.Hardware -eq 2) 'CUDA updates did not reach their hardware checks.'
        Check ((Get-SciencePrefixDigest $prefix) -ceq $before) 'CUDA solver failure rewrote metadata.'

    }
    Case 'cuda-probes-verified-overrides-and-rejects-hardware-mismatch' {
        $fixture.Seen=@()
        $fixture.Architecture='12.0'
        function Get-ScienceNvidiaCudaHardware {
            return [pscustomobject]@{Driver='13.2';Architecture='12.0';DriverRelease='595.99.02'}
        }
        function Get-ScienceCudaVirtualPackages {
            param($Layout,[hashtable]$Overrides=@{})
            $fixture.Seen+=@($Overrides.Clone())
            if(-not $Overrides.Count){return @{'__cuda'='12.9'}}
            return @{'__cuda'='13.2';'__cuda_arch'=$fixture.Architecture}
        }
        $settings=Get-ScienceCudaSolverSettings @{}
        Check ($settings.Overrides['CONDA_OVERRIDE_CUDA'] -ceq '13.2' -and
               $settings.Overrides['CONDA_OVERRIDE_CUDA_ARCH'] -ceq '12.0') 'Verified subprocess overrides missing.'
        Check ($fixture.Seen[0].Count -eq 0) 'Initial probe received an override.'
        $fixture.Architecture='12.1'
        Reject {Get-ScienceCudaSolverSettings @{}} 'different from the verified hardware'
    }
    Case 'cuda-same-major-retry-and-hardware-validation' {
        $cuda=[pscustomobject]@{Architecture='12.0';RuntimeLimit='13.3';MinorLimit='14.0'}
        $cap=@{'cuda-arch'=@{version='7.5'}; 'cuda-version'=@{
            version='13.5';url='https://conda.anaconda.org/conda-forge/noarch/cuda-version-fixture.conda'
            constrains=@('__cuda >=13')
        }}
        Check (Assert-ScienceCudaSolution $cap $cuda) 'Official minor-version compatibility was not recognized.'
        $cap['cuda-arch'].version='12.1'
        Reject {Assert-ScienceCudaSolution $cap $cuda} 'GPU compute capability'
        $cap['cuda-arch'].version='7.5'
        $cap['cuda-version'].version='14.0'
        Reject {Assert-ScienceCudaSolution $cap $cuda} 'exceeds the verified driver'
        $fixture.Solves=0
        function Invoke-ScienceNative {
            param($Executable,$Arguments,$Environment)
            Check ($Environment['CONDA_OVERRIDE_CUDA'] -ceq '13.2') 'Verified driver was not scoped to solver.'
            $fixture.Solves++
            if($fixture.Solves -eq 1){return @{ExitCode=1;Stdout='{"solver_problems":["requires cuda-version >=13.4"]}';Stderr=''}}
            Check ($Arguments -ccontains 'cuda-version<14') 'Retry did not retain the major-version limit.'
            return @{ExitCode=0;Stdout='{"success":true}';Stderr=''}
        }
        $layout=[pscustomobject]@{Root=$work;Science=(Join-Path $work 'envs/science');Pkgs=$work;Tmp=$work;Micromamba='fixture'}
        $retry=@('update','--dry-run','cuda-version<14')
        $plan=Invoke-ScienceMambaJson $layout @('update','--dry-run','cuda-version<13.3') -CudaOverrides @{CONDA_OVERRIDE_CUDA='13.2'} -CudaRetryArguments $retry
        Check ($plan.success -and $fixture.Solves -eq 2) 'Expected one targeted retry.'
    }
    Write-Host ('RESULT tests='+$fixture.Passed+' failed=0')
} finally {
    $env:LOCALAPPDATA=$previousLocalAppData
    Remove-Item -LiteralPath $work -Force -Recurse
}
