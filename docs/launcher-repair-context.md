# Script context for standalone Spyder launcher repair

`09-repair-launchers.ps1` extracts only the AST for `Install-SpyderLauncher` from the integrity-checked `02-install-science.ps1`. The installer body is bypassed. Creating a script block with `[scriptblock]::Create(functionText)` loses the original file context, leaving `$PSScriptRoot` empty inside the extracted function. The first `Join-Path $PSScriptRoot 'science-launcher-common.ps1'` call failed after approval and before any launchers were written. The failure came from the empty script root. `Layout.Root`, `Layout.Bin`, `Layout.Science` and `SystemRoot` already resolved correctly.

The function accepts a `SourceDirectory` parameter that defaults to `$PSScriptRoot` when the main installer calls it. The standalone repair script explicitly passes its own integrity-checked directory.

```powershell
Install-SpyderLauncher -Layout $layout -SourceDirectory $PSScriptRoot
```

Both source-file `Join-Path` calls use this parameter. The selected layout and the shared launcher path helper still determine the destination paths. The repair retains the package identity checks, configuration and Micromamba hashes, interactive `[y/N]` approval, active-use check, update lock and protection for shortcuts that point elsewhere.

## Regression coverage

`tests/test_launcher_repair.ps1` launches the `09-repair-launchers.ps1` entry point from a real `.ps1` file in a separate Windows PowerShell 5.1 process. Test bootstrap files substitute temporary fixture paths at the user and operating-system boundaries and simulate console responses. Production code compares all 490 synthetic package identities, checks the release's foundation requirements and runs the launcher function. `WScript.Shell` creates and reads real `.lnk` files only in the temporary test directory. The tests run without starting Python, Spyder or Micromamba.

Coverage includes approval, repeat runs, check-only mode, No or an empty response, non-interactive execution, package identity, configuration and executable mismatches, an active environment, inputs that change while approval is pending, and shortcuts pointing elsewhere. A regression case reproduces the original context error by omitting `SourceDirectory`. A separate case verifies the default for a function defined directly in a file.

## Manual repair

Close Spyder and other Python processes using the environment, then deactivate `science`. In its default mode, `09-repair-launchers.ps1` checks the repair plan. Review it before adding `-Apply`, which requires an interactive console and separate approval with No as the default. The repair writes only the launchers and their shared helper. Package-source finalization, installer state reports and historical commit evidence are separate.
