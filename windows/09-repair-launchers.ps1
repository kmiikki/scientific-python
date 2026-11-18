[CmdletBinding()]
param(
    [ValidateSet('Home','Safe')][string]$Mode='Home',
    [Parameter(Mandatory=$true)][string]$TransactionDirectory,
    [switch]$Apply
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot
. (Join-Path $PSScriptRoot 'science-common.ps1')
. (Join-Path $PSScriptRoot 'science-release.ps1')
. (Join-Path $PSScriptRoot 'science-launcher-common.ps1')
. (Join-Path $PSScriptRoot 'science-update.ps1')
$layout=Get-ScienceLayoutByMode -Mode $Mode
$transaction=[IO.Path]::GetFullPath($TransactionDirectory)
Assert-ScienceTransactionPath $transaction
if([IO.Path]::GetFullPath((Split-Path $transaction -Parent)).TrimEnd('\') -ine [IO.Path]::GetFullPath($layout.Tmp).TrimEnd('\') -or (Split-Path $transaction -Leaf) -notmatch '^science-transaction-[0-9a-f]{32}$'){throw 'Repair evidence must be a transaction directory in the selected supported root.'}
$lockPath=Join-Path $transaction 'approved-lock.json';Assert-ScienceRegularPath $lockPath
$lock=Read-ScienceJson $lockPath
if([IO.Path]::GetFullPath($lock.prefix) -ine [IO.Path]::GetFullPath($layout.Science)){throw 'Repair evidence targets another environment.'}
$config=Get-ScienceConfigurationPath
$configHash=Get-ScienceFileSha256 $config;$lockHash=Get-ScienceFileSha256 $lockPath
if($configHash -cne $lock.config_sha256){throw 'Configuration differs from the approved transaction.'}
if((Get-ScienceFileSha256 $layout.Micromamba) -cne $lock.executable_sha256){throw 'Micromamba identity differs from the approved transaction.'}
$records=Get-ScienceRecords $layout.Science
$signature=Get-ScienceRecordSignature @($records.Values)
if($signature -cne (Get-ScienceRecordSignature @($lock.after))){throw 'Installed package identities do not match the approved final universe.'}
$null=Assert-SciencePlan ([pscustomobject]@{success=$true;actions=$null}) $records (Get-ScienceMediaFloors $records) @(Get-SciencePackageSpecs)
$python=Join-Path $layout.Science 'python.exe';$spyder=Join-Path $layout.Science 'Scripts/spyder.exe'
foreach($path in @($python,$spyder)){Assert-ScienceRegularPath $path}
$paths=Get-ScientificPythonSpyderLauncherPaths -Layout $layout
$summary=[ordered]@{mode=$Mode;prefix=$layout.Science;installed_identities_verified=$records.Count;support=(Join-Path $layout.Root 'science-launcher-common.ps1');script=$paths.Script;command=$paths.Command;shortcut=$paths.Shortcut;apply=[bool]$Apply;native_transaction_invoked=$false;historical_native_exit_code='not recorded';source_metadata_finalization='not repaired by this launcher-only action'}
if(-not $Apply){$summary|ConvertTo-Json;Write-Host 'Check only. Re-run with -Apply for an interactive launcher-only repair; no package transaction will be run.';exit 0}
if(-not (Test-ScienceInteractiveConfiguration)){throw 'Launcher repair requires an interactive console.'}
Assert-ScienceNotInUse $layout
Write-Host ($summary|ConvertTo-Json)
if((Read-Host 'Create/repair only these Spyder launchers? [y/N]').Trim() -notmatch '^(?i:y|yes)$'){Write-Host 'Repair cancelled; no launcher changes made.';exit 0}
$exclusive=$null
try {
    $exclusive=[IO.File]::Open((Join-Path $layout.Root '.science-update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    Assert-ScienceNotInUse $layout
    if((Get-ScienceFileSha256 $config) -cne $configHash -or (Get-ScienceFileSha256 $lockPath) -cne $lockHash -or (Get-ScienceRecordSignature @((Get-ScienceRecords $layout.Science).Values)) -cne $signature){throw 'Repair inputs changed while awaiting approval.'}
    # Load only the existing verified launcher function, never the installer body.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '02-install-science.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Installer source could not be parsed.'}
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Install-SpyderLauncher'},$true))
    if($functions.Count -ne 1){throw 'Expected one verified launcher function.'}
    function Stop-Install {param([string]$Message);throw $Message}
    . ([scriptblock]::Create($functions[0].Extent.Text))
    # Text extraction loses the function's original PSScriptRoot. Pass our verified bundle directory.
    Install-SpyderLauncher -Layout $layout -SourceDirectory $PSScriptRoot
    if((Get-ScienceRecordSignature @((Get-ScienceRecords $layout.Science).Values)) -cne $signature){throw 'Package state changed during launcher repair.'}
    Write-Host 'Spyder launchers repaired. No package transaction, historical commit receipt, or package-source metadata was changed.'
} finally {if($exclusive){$exclusive.Dispose()}}
