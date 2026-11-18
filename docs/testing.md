# Testing and acceptance

## Niobium native acceptance

On 2026-11-18, the maintainer completed the minimum v0.9.0 native acceptance on Niobium with Ubuntu 24.04 LTS, using the existing Science environment and development revision `333feee`.

| Test | Result | Evidence |
|---|---|---|
| Install/update | PASS | 4 package upgrades, 4 rebuilds, 0 removals. The native transaction, automatic runtime tests and Spyder launchers passed. |
| Environment-in-use protection | PASS | The installer blocked the update while another Bash session was using Science. **Recheck** let the update proceed after that session closed. |
| Optional PyTorch CUDA installation | PASS | The maintainer selected CUDA through **O — Optional packages**, reviewed and approved the plan, and completed the native installation. 38 packages installed, 4 upgrades, 9 rebuilds, 0 removals. Automatic runtime tests passed. |
| CUDA computation in Spyder | PASS | PyTorch 2.14.1 reported CUDA availability as `True` on an NVIDIA GeForce RTX 5060 Ti. A 1,000 × 1,000 GPU matrix multiplication followed by CUDA synchronization completed on `cuda:0` with result shape `torch.Size([1000, 1000])`. |
| Scientific runtime and launchers | PASS | Python 3.14.10, Spyder 6.1.8, OpenCV 5.1.0, FFmpeg 9.0.2, IPython kernel, Spyder GUI and FFV1/MKV checks passed. |
| Other Micromamba environments | PRESERVED | Both package transactions preserved the other environments. |

The installer reported CUDA **13.5** dependency compatibility. The installed PyTorch build reported **13.4** through `torch.version.cuda`. Both are the observed values from the same accepted workflow.

Windows 11 and Ubuntu 26.04 native acceptance of the current snapshot remains pending. This Niobium test covers updating an existing environment. It leaves the fresh-install and removal paths for separate acceptance.

## v0.9.0 regression history

| Change | Python | PowerShell on Linux | Additional evidence |
|---|---:|---:|---|
| Optional PyTorch installer menus (`c290529`) | 56/56 PASS | 163/163 PASS | CPU and CUDA selection, configuration backups, cancellation and no-op handling. |
| CUDA compatibility correction (`333feee`) | 60/60 PASS | 165/165 PASS | Source and recovery suites, PowerShell parsing, source integrity and the isolated Niobium CUDA solver check passed. That dry run stopped at approval. The native installation and computation results are recorded above. |

## v0.1.0 preparation and follow-up (historical)

Date: 2026-11-17. These checks support **v0.1.0 Development Release preparation**, not native target-system acceptance.

### Release-default addition follow-up

The current follow-up adds shared Python/PowerShell configuration-upgrade cases and report tests. It verifies approval/decline, non-interactive preservation, identity matching, customization, atomic failures, unrelated synthetic environments and the native solve boundary. Results: Python **37/37**, PowerShell configuration **67/67**, locked transactions **23/23**, Bash/entry smoke **11/11**, source/platform manifest and Markdown audits passed. Full logs are recorded with the local delivery. The previous tables below remain historical evidence. See [configuration additions and final native acceptance](release-package-upgrade.md).

No production Science installation/update is performed during this follow-up. Windows configuration and event tests run on Linux PowerShell 7.4.6; native Windows acceptance remains pending.

### Spyder startup fix verification

The focused v0.1.0 follow-up ran **26 Python tests successfully, with one PowerShell-dependent test skipped** (27 discovered). The ten new activation/startup methods cover home/unrelated working directories, source and installed-style bundles, foreign cached module names, integrity failure, managed launcher targeting and Science interpreter configuration. The original source reproduces the reported missing-module error; the corrected source passes.

A real headless `spyder_kernels.console` was started using the existing Science Python with temporary profiles/caches. It executed the corrected imports from the user's home directory and verified the Science interpreter/prefix and media tool paths. All environment inventories and installed support matched; a native file-write audit confirmed that the test did not write existing home-directory settings. Concurrent live profile changes were retained. Full GUI-connected console acceptance remains pending. See the [focused report](spyder-startup-fix.md).

PowerShell/Windows transaction suites below are retained initial-preparation evidence and were not rerun for this Linux-only change.

### Initial preparation checks (retained evidence)

| Check | Result | Scope |
|---|---|---|
| Python unittest | 17/17 passed | Shared fixtures, migration, mutable JSON/immutable manifests, channel and entry-point regressions, reordered media preview |
| PowerShell configuration/entry tests | 51/51 passed | Linux PowerShell 7.4.6; shared fixtures, migration/backups/idempotence, actual error-preference assignments and launcher helper loading |
| Windows transaction tests | 23/23 passed | Linux PowerShell 7.4.6 + native Linux Micromamba 2.10.0; inert noarch packages with Windows target selection |
| Bash syntax and Linux CLI entry smoke | 11/11 passed | All shipped Bash files; installer `--help`; safe menu quit/config-location paths |
| Distribution and source integrity | Passed | Public file allowlist, source/platform hashes, extracted distribution structure and Markdown links |

Transaction tests cover a fresh explicit create, frozen version update, same-version build change, preserved independent user package, missing-payload same-identity relink, cancellation, SHA/UNLINK/prefix/duplicate-name failures and missing approval seal. Deliberate changes to configuration, in-memory lock, lock file, native input, archive, installed identities, metadata/history and executable all stop before package commit. A mocked mismatching native preflight proves the commit is not called. Native positive paths use the real Micromamba executor; small synthetic packages contain only inert text, not scripts or native code.

All temporary runtimes, fixtures, package roots and caches used for preparation are under RAM-backed `/tmp`. Native test processes receive a private temporary home so fixture registration does not change the user's environment index. Test roots are removed automatically. No existing Science or other Python environment was modified; Micromamba was not removed.

### Maintainer commands

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

### Prior evidence retained

The earlier bounded package-selection and Bleach investigation evidence remains locally unchanged. The four Bleach dry runs are **prior evidence**, not rerun release-preparation results. No permanent Bleach/tinycss2 pin was added. No broad solver matrix was repeated.

### Not run / not accepted

- Native Windows 11 / Windows PowerShell 5.1 installation, removal, bootstrap, DLL/hooks and launcher acceptance.
- Complete Ubuntu 24.04 or 26.04 remove/install acceptance.
- Spyder GUI startup and its first connected IPython console, real media/GUI checks and launcher persistence after login. The focused headless Science kernel check is recorded above.
- Full scientific environment installation during this preparation.
- Optional-package combination matrix, broad CUDA/GPU testing or synchronization/retirement tests.

Record the status of these platform checks with the milestone under the [development and publication policy](release-checklist.md).
