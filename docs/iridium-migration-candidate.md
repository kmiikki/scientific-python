# Iridium migration candidate — v0.9.0 development

The previously observed stop happens before solving: the executable-selection path expects a V4 root or promotion receipt, and the Science guard requires a separate environment receipt. Ubuntu LTS V3 wrote neither. The archived V3 installer instead wrote `.scientific-python-installer-state` after its import checks and launcher setup. It recorded the home layout, Python 3.14, Spyder 6.1.7 and Micromamba 2.8.1. The exact historical launcher and package command can corroborate that state; a folder name or package list by itself cannot.

This candidate checks the historical state, safe directory identities, launcher and Conda history, package provenance and V3 anchors. Newer completed states also need the matching in-prefix marker and installed-package fingerprint. A proposed migration is separate from Micromamba promotion and package approval. The migration receipt authorizes updating the same directory and does not permit Science removal before a verified update. No migration changes the root or binary ownership receipts. An unresolved configuration, altered evidence or unsupported historical format must stop; restore trusted original files or choose a separate new root and leave the old prefix in place.

The inventory is bounded to known locations, explicit environment settings, recorded roots, PATH and registered Conda prefixes. It is not a disk-wide search. Ubuntu probes only vetted native binaries in an isolated profile. Windows does not execute discovered binaries for inventory; custom candidates need a trusted executable inside the selected root. Diagnostics report Windows inventory counts without exposing private paths.

Total Remove accepts multiple direct Conda environments and base. It verifies Conda package inventories, private cache layouts, directory ownership, a trusted executable and bounded installer artifacts before offering a plan. An installer-created root and a dedicated, independently verifiable user-managed root are distinct cases; cleanup does not create an ownership receipt on a manual root. Unknown content or ownership, overlapping roots, links or mounts leaving the target, cache sharing, active use and changed identities block deletion. Production confirmation requires an interactive terminal, the literal displayed path for a non-default root, and `Yes, I do understand.` twice.

Windows holds ancestor handles against replacement, rejects reparse points, checks write/delete ACLs and tests exclusive file access before removing each approved identity with a native handle. Windows can preserve unrelated user settings while cleaning matching environment variables and verified launchers. Unknown profile references are left for review. Linux uses descriptor-relative removal of approved entries and does not rewrite unknown Bash integration. A partial failure reports the first affected target; no rollback is promised.

During approved native package execution, the installer can show a roughly five-second heartbeat based on whether its child process is still active. It does not estimate a package count or completion percentage. Incomplete or oversized transaction output cannot count as a verified commit.

## Physical acceptance gate

Run on disposable or explicitly approved targets only. Keep the package plans and record the candidate commit. Do not publish v0.9.0 based on the local fixture tests.

| Host | Confirm before release |
|---|---|
| Iridium — Ubuntu 26.04 | Existing root, genuine original metadata, in-place migration, preserved third-party root/cache and other environments; separate binary and package approvals; Python, Spyder and first kernel; CPU PyTorch flow. |
| HP Z240 — Ubuntu 26.04 | New root defaults, saved configuration and optional selection; visible heartbeat; fresh install and update; Science-only removal and Total Remove rejection/success only on an approved disposable root. Check that a second root and an external environment remain untouched. |
| Niobium — Ubuntu 24.04 | Verify that the prior CUDA acceptance still applies to the new commit. Recheck existing update, package restrictions, launcher and CUDA runtime on the actual GPU. |
| Windows 11 | Run the isolated Windows PowerShell 5.1 verification script below. For native menu acceptance, review the inventory and whole-root plan using only a disposable target. |

In Windows PowerShell 5.1, from the unpacked project:

```powershell
& .\tests\verify_windows_powershell51.ps1
```

This does not change execution policy or touch real package environments. If script authorization is blocked, retain the complete output for review; do not change organizational or machine policy for this test.

## Build and transfer

From the development checkout with the intended commit checked out:

```sh
git rev-parse HEAD
git archive --format=zip --prefix=scientific-python-fix-iridium-legacy-migration/ \
  --output=scientific-python-iridium-test.zip HEAD
git bundle create scientific-python-fix-iridium-legacy-migration.bundle fix/iridium-legacy-migration
git bundle verify scientific-python-fix-iridium-legacy-migration.bundle
sha256sum scientific-python-iridium-test.zip scientific-python-fix-iridium-legacy-migration.bundle
```

Recompute SHA-256 after copying to T9 and again on the destination. `git bundle list-heads` must show `refs/heads/fix/iridium-legacy-migration` at the recorded commit. To check out the candidate on Niobium without changing any remote, use `git clone -b fix/iridium-legacy-migration scientific-python-fix-iridium-legacy-migration.bundle scientific-python-iridium` in a new directory. On Iridium unpack the whole ZIP and run `bash linux/00-menu.sh` from its single top-level folder. Use **I — Info** and **Existing** to verify the selected executable and root before accepting anything.
