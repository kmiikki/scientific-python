# Testing and acceptance

## v0.9.2 Ubuntu 24.04 LTS acceptance

These workflows passed in a native Ubuntu 24.04 LTS test on x86-64.

| Check | Result | Evidence |
|---|---|---|
| Fresh installation without PyTorch | PASS | No PyTorch selected. The approved plan left PyTorch out. |
| Fresh installation with NVIDIA CUDA | PASS | The CUDA package transaction and automatic checks completed. |
| CUDA computation | PASS | PyTorch 2.13.0 completed computation on a CUDA-capable NVIDIA GPU. |
| Science removal without PyTorch | PASS | 9 seconds. Other environments and shared cache were preserved. |
| Science removal with CUDA PyTorch | PASS | 10 seconds. Other environments and shared cache were preserved. |
| USB Camera Test | PASS | Native V4L2 capture and preview passed. |
| Installation progress | PASS | Native terminal run used the installer monitor with a simulated Micromamba child and delayed Python verification. |

The earlier Science removal took 107 seconds in the same test setup. These are observed times for **3 — Remove Science environment**. To compare versions, use equivalent disposable test directories with the same package set, sibling environments and cache, then time the complete Science removal and verify preservation. Total Remove was tested separately on disposable Linux roots and in two earlier Ubuntu 26.04 LTS hotfix checks.

The installation progress regression run passed **86 Python tests**, **147 PowerShell tests** and **C# 5 compilation**. PowerShell ran under Linux. The simulator exercises the real installer transaction and progress path with inert package records in an isolated directory. Run it from the source checkout on Ubuntu.

```bash
python3 -B tests/test_install_progress.py --native
```

Look for `00:00` when the approved phase starts. In the simulator, `00:05` and `00:10` show Micromamba activity, and `00:15` and `00:20` show Python verification. The clock stops at the package-phase `PASS`. This test leaves the installed environments and package caches untouched.

## Windows 11 native acceptance pending

Integrated v0.9.2 installation, update and removal under native Windows PowerShell 5.1 remain **PENDING**. The earlier Windows camera test is recorded separately below.

Use a verified ZIP and an approved disposable Home or Safe layout. Install and update the same Science environment. Check the package phase, first Spyder console, OpenCL/FFV1 and the HDF5 compatibility sample. Keep a sentinel environment beside Science. Use **5 — Remove Science environment** and verify that Micromamba and the sentinel remain. Test **M — Remove Micromamba installed by Scientific Python** only with a disposable installer-owned executable and matching receipt. Use **6 — Total Remove** only on a disposable directory, with a second directory and an external file to preserve. Verify the selected directory and its arbitrary contents disappear while those external targets remain.

## v0.9.1 camera hardware acceptance

Physical capture and preview are separate from installer and runtime acceptance. Automated camera regressions use simulated devices and bounded worker processes.

| Target | Required physical check | Status |
|---|---|---|
| Windows 11 | DirectShow capture and preview in the installed Science environment | PASS at `dce8fa56`; Windows PowerShell 5.1 |
| Ubuntu 24.04 LTS | V4L2 capture and preview | PASS on the earlier v0.9.1 camera implementation |
| Ubuntu 26.04 LTS, first test | V4L2 capture and preview | Historical acceptance reported by the maintainer. Detailed device results are unavailable in this checkout. |
| Ubuntu 26.04 LTS, second test | Independent device results, including unsupported interfaces where applicable | Historical acceptance reported by the maintainer. Detailed device results are unavailable in this checkout. |

Follow the [camera test instructions](camera-testing.md). Record the commit, backend, per-device status, observed resolution and preview result. Include a capture-only check and, if available, a functional camera alongside an unsupported or inaccessible device.

The Windows 11 camera test of v0.9.1 at `dce8fa56` included discovery fix `62b5d67`. DirectShow returned three consecutive valid 640×480 frames. The first preview was visible and ran for about five seconds. Single-camera selection and **Test all** passed. This was a camera check. Integrated installer acceptance is tracked separately.

The Ubuntu 24.04 LTS V4L2 test produced three valid 640×480 frames and displayed a preview. A metadata-only node returned `UNSUPPORTED (NO_VIDEO_CAPTURE)`. **Test all** passed.

The v0.9.1 automated run passed 93 Python tests. On Linux PowerShell 7.4.6, eleven PowerShell suites passed, including the inert Micromamba transaction test. The native-Windows launcher repair and NTFS whole-root removal suites could not complete on Linux and reproduced the same host limitations on the baseline. Both versioned ZIPs passed extraction and manifest verification. A camera-free Ubuntu run returned `SKIP (NO_CAMERA)`. The installed Science environment was used for a device list and a read-only OpenCV backend check.

## v0.9.1 lifecycle verification

Two Ubuntu 26.04 LTS systems passed the cumulative Linux hotfix before integration. The integration was also checked with real Micromamba 2.10.0 and offline inert packages in disposable Linux roots. The fixture created two environments in each of two roots. Science-only removal preserved its sibling environment and cache, and the same prefix could be recreated. Whole-root removal then deleted the selected directory with arbitrary files and group-write access while preserving the second root, shell settings and external registry entries.

Windows policy and transaction fixtures were exercised on Linux PowerShell. See the [current Windows acceptance scope](#windows-11-native-acceptance-pending) for native rights and junction handling.

## v0.9.0 Ubuntu 24.04 LTS acceptance

The v0.9.0 native test used Ubuntu 24.04 LTS, an existing Science environment and development revision `333feee`.

| Test | Result | Evidence |
|---|---|---|
| Install/update | PASS | 4 package upgrades, 4 rebuilds, 0 removals. The native transaction, automatic runtime tests and Spyder launchers passed. |
| Environment-in-use protection | PASS | The installer blocked the update while another Bash session was using Science. **Recheck** let the update proceed after that session closed. |
| Optional PyTorch CUDA installation | PASS | In the v0.9.0 optional-packages menu the maintainer selected CUDA, reviewed and approved the plan, and completed the native installation. 38 packages installed, 4 upgrades, 9 rebuilds, 0 removals. Automatic runtime tests passed. |
| CUDA computation in Spyder | PASS | PyTorch 2.14.1 reported CUDA availability as `True` on a CUDA-capable NVIDIA GPU. A 1,000 × 1,000 GPU matrix multiplication followed by CUDA synchronization completed on `cuda:0` with result shape `torch.Size([1000, 1000])`. |
| Scientific runtime and launchers | PASS | Python 3.14.10, Spyder 6.1.8, OpenCV 5.1.0, FFmpeg 9.0.2, IPython kernel, Spyder GUI and FFV1/MKV checks passed. |
| Other Micromamba environments | PRESERVED | Both package transactions preserved the other environments. |

The installer reported CUDA **13.5** dependency compatibility. The installed PyTorch build reported **13.4** through `torch.version.cuda`. Both are the observed values from the same accepted workflow.

This v0.9.0 Ubuntu 24.04 LTS test covered updating an existing environment. The [0.9.2 fresh-install and removal results](#v092-ubuntu-2404-lts-acceptance) are recorded above.

## v0.9.0 regression history

| Change | Python | PowerShell on Linux | Additional evidence |
|---|---:|---:|---|
| Optional PyTorch installer menus (`c290529`) | 56/56 PASS | 163/163 PASS | CPU and CUDA selection, configuration backups, cancellation and no-op handling. |
| CUDA compatibility correction (`333feee`) | 60/60 PASS | 165/165 PASS | Source and recovery suites, PowerShell parsing, source integrity and the isolated Ubuntu 24.04 LTS CUDA solver check passed. That dry run stopped at approval. The native installation and computation results are recorded above. |

## v0.1.0 preparation and follow-up (historical)

These checks were part of **v0.1.0 Development Release preparation**. Native target-system acceptance is recorded separately.

### Release-default addition follow-up

The v0.1.0 follow-up added shared Python/PowerShell configuration-upgrade cases and report tests. It verifies approval/decline, non-interactive preservation, identity matching, customization, atomic failures, unrelated synthetic environments and the native solve boundary. Results: Python **37/37**, PowerShell configuration **67/67**, locked transactions **23/23**, Bash/entry smoke **11/11**, source/platform manifest and Markdown audits passed. Full logs are recorded with the local delivery. The previous tables below remain historical evidence. See [configuration additions and final native acceptance](release-package-upgrade.md).

During that follow-up, verification used isolated fixtures. The Windows configuration and event tests ran on Linux PowerShell 7.4.6.

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
