[CmdletBinding()]
param([ValidateSet('Auto','Home','Safe')][string]$Mode='Auto')
. (Join-Path $PSScriptRoot 'science-integrity.ps1')
Assert-ScienceBundle $PSScriptRoot
$ErrorActionPreference='Stop'

# The previous implementation could recursively remove a manual installation.
# Block the original entry point as well as the menu until Windows root and
# cache exclusivity can be independently established.
Write-Host 'Whole-root Micromamba removal is unavailable on Windows in this development snapshot.' -ForegroundColor Yellow
Write-Host 'The root, executable, cache, registry and user settings were preserved. Use Remove Science for a verified Science-only removal.'
exit 2
