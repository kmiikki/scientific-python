# Release-preparation test report

Date: 2026-11-17. These checks support **v0.1.0 Development Release preparation**, not native target-system acceptance.

## Completed automated checks

| Check | Result | Scope |
|---|---|---|
| Python unittest | 17/17 passed | Shared fixtures, migration, mutable JSON/immutable manifests, channel and entry-point regressions, reordered media preview |
| PowerShell configuration/entry tests | 51/51 passed | Linux PowerShell 7.4.6; shared fixtures, migration/backups/idempotence, actual error-preference assignments and launcher helper loading |
| Windows transaction tests | 23/23 passed | Linux PowerShell 7.4.6 + native Linux Micromamba 2.10.0; inert noarch packages with Windows target selection |
| Bash syntax and Linux CLI entry smoke | 11/11 passed | All shipped Bash files; installer `--help`; safe menu quit/config-location paths |
| Distribution and source integrity | Passed | Public file allowlist, source/platform hashes, extracted distribution structure and Markdown links |

Transaction tests cover a fresh explicit create, frozen version update, same-version build change, preserved independent user package, missing-payload same-identity relink, cancellation, SHA/UNLINK/prefix/duplicate-name failures and missing approval seal. Deliberate changes to configuration, in-memory lock, lock file, native input, archive, installed identities, metadata/history and executable all stop before package commit. A mocked mismatching native preflight proves the commit is not called. Native positive paths use the real Micromamba executor; small synthetic packages contain only inert text, not scripts or native code.

All temporary runtimes, fixtures, package roots and caches used for preparation are under RAM-backed `/tmp`. Native test processes receive a private temporary home so fixture registration does not change the user's environment index. Test roots are removed automatically. No existing Science or other Python environment was modified; Micromamba was not removed.

## Maintainer commands

Run from the project root. These commands are for development verification; users customize packages through JSON and the menu.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s tests -v
pwsh -NoLogo -NoProfile -File tests/test_configuration.ps1
python3 tests/make_transaction_fixtures.py /tmp/science-contract-fixtures
pwsh -NoLogo -NoProfile -File tests/test_transaction.ps1 \
  -Micromamba /path/to/micromamba-2.10.0 \
  -Fixtures /tmp/science-contract-fixtures -TempRoot /tmp
python3 tools/audit_release.py
```

Use temporary XDG cache/config/data directories when running portable PowerShell. Remove the generated fixture directory after testing. The transaction test deliberately accepts an explicit test binary path; the production wrapper separately requires the immutable Windows bootstrap hash.

## Prior evidence retained

The earlier bounded package-selection and Bleach investigation evidence remains locally unchanged. The four Bleach dry runs are **prior evidence**, not rerun release-preparation results. No permanent Bleach/tinycss2 pin was added. No broad solver matrix was repeated.

## Not run / not accepted

- Native Windows 11 / Windows PowerShell 5.1 installation, removal, bootstrap, DLL/hooks and launcher acceptance.
- Complete Ubuntu 24.04 or 26.04 remove/install acceptance.
- Spyder GUI startup, first IPython kernel, real media/GUI checks and launcher persistence after login.
- Full scientific environment installation during this preparation.
- Optional-package combination matrix, broad CUDA/GPU testing or synchronization/retirement tests.

These remain explicit manual release checks in the [release checklist](release-checklist.md).
