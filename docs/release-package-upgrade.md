# Release package additions and verification — v0.1.0

## Root cause

The active per-user JSON had 35 direct requests: the original 29 scientific requests plus six foundations. The shared default already had 42, including `shap`, `pywavelets`, `optuna`, `plotly`, `hypothesis`, `polars` and `xgboost`.

This was configuration preservation, not a solver failure:

1. Linux `science_config.initialize()` creates the full default on a clean installation. A valid existing schema-v1 file is returned unchanged; legacy migration preserves the old scientific list and supplies only missing foundation requests.
2. Windows `Initialize-ScienceConfiguration` follows the same policy, including parsing the matching legacy PowerShell list when needed.
3. Install/update obtains its requests from the resulting effective user JSON. The seven absent requests therefore never reached Micromamba.
4. Both runtime checkers filtered imports by effective requested package names. Their seven-package import mapping was already present, but those imports were deliberately excluded when absent from the effective list. Existing successful checks established effective-configuration compliance, not complete release-default coverage.
5. Existing tests explicitly protected this behavior: legacy selections do not automatically acquire Polars, and new source distributions do not overwrite a user-edited list. They did not test an opt-in default-addition proposal or report the default/effective distinction.

`shapely` and `shap` are separate identities. The comparison and tests keep them separate.

## New behavior

After safe initialization/migration, interactive **Install/update** compares the active requests with the current platform's defaults using package identities. Versions, builds, channel qualifiers and accepted MatchSpec attributes do not make an already represented package missing.

The installer displays absent default requests and asks:

```text
Add these release requests to your configuration? [y/N]
```

The default is **No**. Declining leaves the file bytes, BOM, permissions and timestamp unchanged. Accepting appends only the displayed missing requests; existing entries, constraints, channels and supported settings are preserved. No existing request is removed or replaced. Already represented constrained requests are retained exactly.

The comparison includes any default name absent from the user list, including a previously deliberate omission. Nothing is silently restored. Decline if you want to retain those omissions, or edit only selected requests in the same JSON. A declined difference can be offered again on a later interactive update; no hidden dismissal database is introduced.

Fresh installations already receive all 42 default requests and need no addition prompt. Repeating an approved update creates no duplicate requests and does not rewrite an already complete configuration.

Linux requires terminal input/output for the new prompt. Windows checks ConsoleHost, input/output redirection and `-NonInteractive`. Non-interactive workflows preserve the active file and report the differences without prompting. There is no new unattended synchronization switch; prepare an explicitly edited JSON when unattended operation requires a different selection.

## Configuration and package transaction safety

The candidate is validated before replacement. The original file remains in place until a same-directory staged file is ready. Linux uses atomic replacement and preserves the existing POSIX permission mode. Windows uses `File.Replace` with destination ACL semantics. A changed source during the approval window aborts replacement. Normal failure removes staging files and preserves the active original; an abrupt process termination may leave a staging file, but does not intentionally replace the active configuration with partial JSON.

No new backup series is created for these additions. Existing legacy migration backups remain unaffected. The Windows writer also uses a typed null backup path for `File.Replace`, avoiding PowerShell's empty-string conversion.

Configuration approval and package-event approval are separate. After the configuration update, the existing Micromamba solve, plan display, identity lock and error-handling path remain in use. No new force-reinstall, ownership, removal or rollback mechanism is introduced. An incompatible solve fails explicitly; approved requests remain in JSON and are not silently dropped. If you cancel the package event, the approved configuration additions remain available for the next attempt.

## Verification scope

Both runtime checkers use one small shared reporting module. The report separates:

| Field | Meaning |
|---|---|
| `effective_requested` | Package identities required by the active user configuration |
| `release_defaults` | Package identities in the release template |
| `installed` | Package identities read from the selected Science Conda metadata |
| `missing_effective` | Required identities absent from that environment; a failure |
| `release_not_requested` | Default identities the user configuration omits; a separately reported difference |
| `release_not_installed` | Default identities absent from the environment |
| `import_checks`, `verified_imports` | Recorded import outcomes and package identities whose recorded imports passed |
| `imports_not_checked` | Requests without an import result; this is not a claim that they were imported |

Effective configuration status may pass while release-default coverage is incomplete. The installer prints the two scopes separately. A failed requested import fails verification. Package presence alone does not establish every arbitrary MatchSpec restriction; the existing native solve/locked transaction and foundation/variant checks remain responsible for those constraints.

The seven import mappings are `shap→shap`, `pywavelets→pywt`, `optuna→optuna`, `plotly→plotly`, `hypothesis→hypothesis`, `polars→polars`, `xgboost→xgboost`. They are checked only when requested, in the existing runtime smoke step. No extra heavyweight imports are added to configuration, bootstrap or solver phases.

## Automated evidence and limits

Results: **Python 37/37**, **PowerShell 67/67**, **locked transaction 23/23**, **Bash/entry smoke 11/11**, plus source/platform manifest and Markdown audits passed. Python counts test methods, including shared-case subtests; PowerShell counts individual cases. The extracted release ZIP is checked again before delivery.

Focused Python and PowerShell tests share nine upgrade scenarios. They cover clean defaults, approval, decline/default-No, non-interactive preservation, constraints, additions, channels, qualified/attribute/space MatchSpecs, identity matching, idempotence and `shap` versus `shapely`. Additional tests cover invalid candidates, concurrent edits, atomic write failure/cleanup, preserved permissions, synthetic unrelated environments, updated native solve requests, solver failure and effective/default/import reporting.

The existing startup/activation regressions from commit `923b785` and approved-event transaction tests remain enabled. Tests use RAM-backed `/tmp`, synthetic roots and no production package operations. Linux PowerShell tests do not certify Windows 11/PowerShell 5.1 terminal, ACL or replacement acceptance.

The user reports that Ubuntu 24.04's base installation, Spyder/kernel and launchers passed native acceptance. This task does not repeat or claim the new seven-package native acceptance. Ubuntu 26.04 and native Windows acceptance remain separate. No dependency matrix was rerun, no package requirements/version were changed and no GitHub publication was performed.

## Final Ubuntu 24.04 acceptance

Use a fresh terminal without activating Science. From the updated project folder:

```bash
bash linux/00-menu.sh
```

1. Choose **1 — Install/update**, then **Existing**, retaining `~/.local/share/mamba` and its current Micromamba executable.
2. Confirm that the configuration proposal lists exactly the seven missing names for the known 35-request configuration. Answer **y**.
3. Review the separate Micromamba package event, including any version/build changes, and approve it. A failed solve must remain a failure with all requested packages retained.
4. Confirm that effective configuration verification passes, release-default omissions are empty, and the other-environments check reports preservation. No uninstall/recreation of the root is required.
5. From a new terminal, start the managed launcher:

   ```bash
   science-spyder
   ```

6. In Spyder's first IPython console run:

   ```python
   import sys
   print(sys.executable)
   import shap
   import pywt
   import optuna
   import plotly
   import hypothesis
   import polars
   import xgboost
   print("Scientific Python Environment: PASS")
   ```

The interpreter must be inside the selected `envs/science` prefix. Confirm the GNOME/desktop launchers and that unrelated environments, including `py314-opencv5-cuda`, remain available. To check the decline path separately, decline the proposal and verify the active JSON remains byte-for-byte unchanged; verification may pass for that effective selection while the seven default differences remain visible.
