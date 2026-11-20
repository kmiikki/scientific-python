# Windows native commit diagnostics and interrupted finalization

The executor verifies the process exit code, one complete JSON object, the `success` value, the target prefix, the approved `LINK` and `UNLINK` identities, and the final installed package identities. A nonzero exit code fails verification even when the JSON reports `success=true`.

Package post-link scripts can write to stdout before Micromamba's JSON object. For example, `spyder-base` moves `gui-64.exe` to `spyder.exe`, and `move` prints a message. The executor parses one complete JSON object at the end of the output and checks it with the shared StrictJson validator. It rejects multiple objects, trailing text and identity mismatches.

Each native phase writes diagnostics to a subdirectory of the transaction evidence directory.

- `native-approved-archive-extraction`
- `native-locked-preflight`
- `native-locked-commit`

Each subdirectory contains `result.json` with the actual exit code and redacted arguments, plus `stdout.txt` and `stderr.txt`. The executor redacts URLs, credentials and tokens before writing the files. It saves the diagnostics before checking the exit code or parsing JSON.

## Commit verification stages

`commit-verification.json` records the last stage reached.

| Stage | Check or action |
| --- | --- |
| `native-commit` | Start the native process. |
| `save-native-diagnostics` | Save the exit code and process output. |
| `native-exit` | Check the native exit code. |
| `native-json` | Parse the native JSON. |
| `native-success` | Check the JSON's `success` value. |
| `reported-prefix` | Verify the prefix reported by the native process. |
| `approved-link-unlink-identities` | Compare the reported actions with the approved package identities. |
| `write-committed-plan` | Write `committed-plan.json`. |
| `installed-identities` | Verify the final installed package identities. |
| `restore-source-metadata` | Restore the original HTTPS source URLs in the package metadata. |
| `final-input-integrity` | Recheck the lock and input files. |
| `complete` | All checks above succeeded. |

The executor sets `completed=true` only at `complete`. Use the final installation status to verify that installer finalization succeeded. `committed-plan.json` records the native commit plan.

## Repair missing launchers separately

`09-repair-launchers.ps1` compares the installed package identities with the `after` set in the selected transaction's `approved-lock.json`. It verifies the package configuration, Micromamba hash, supported Home or Safe layout, and foundation package constraints. By default it reports the repair plan. This entry point runs without invoking the installer body, solver or a package transaction.

In PowerShell, substitute the extracted project path and the actual transaction evidence directory.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\local\scientific-python-windows-hotfix\windows\09-repair-launchers.ps1" -Mode Home -TransactionDirectory "C:\Users\<username>\micromamba\tmp\science-transaction-<transaction-id>"
```

Review the plan before adding `-Apply`. Close Spyder and deactivate `science` before the repair. The script requires an interactive console, checks that the environment is idle and asks for separate approval with No as the default.

The repair loads `Install-SpyderLauncher` from the integrity-checked installer and copies `science-launcher-common.ps1` to the selected root. It creates `start-spyder.ps1`, `science-spyder.cmd` and the desktop Spyder shortcut. Existing shortcuts pointing elsewhere remain protected. The repair leaves `conda-meta`, package-source URLs and `last_sync` unchanged. It leaves any unrecorded native commit receipt or exit code unknown. Source metadata finalization is a separate maintenance operation that requires the same package identity verification. Metadata or launcher finalization can use the installed packages as they are.

## Historical finding

The observed fresh installation reached the approved package identities before installer finalization stopped. The older evidence did not include the native exit code, stdout or stderr, so its exit code remains unknown. An isolated inert fixture reproduced the JSON parsing failure caused by the file-move message. The investigation used that fixture without running another live package transaction.
