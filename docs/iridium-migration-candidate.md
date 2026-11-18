# Iridium migration candidate — v0.9.0 development

The previously observed stop happens before solving: the executable-selection path expects a V4 root or promotion receipt, and the Science guard requires a separate environment receipt. Ubuntu LTS V3 wrote neither. The archived V3 installer instead wrote `.scientific-python-installer-state` after its import checks and launcher setup. It recorded the home layout, Python 3.14, Spyder 6.1.7 and Micromamba 2.8.1. The exact historical launcher and package command can corroborate that state; a folder name or package list by itself cannot.

This candidate checks the historical state, safe directory identities, launcher and Conda history, package provenance and V3 anchors. Newer completed states also need the matching in-prefix marker and installed-package fingerprint. A proposed migration is separate from Micromamba promotion and package approval. The migration receipt authorizes updating the same directory and does not permit Science removal before a verified update. No migration changes the root or binary ownership receipts. An unresolved configuration, altered evidence or unsupported historical format must stop; restore trusted original files or choose a separate new root and leave the old prefix in place.

The Ubuntu inventory is bounded to known paths, recorded roots, shell references and Conda registry entries. Probes run only vetted Micromamba builds with an isolated profile. Unknown references are informational, including stale paths and binaries without a known digest. Custom configuration and possible external caches constrain cleanup. On Windows the candidate checks the supported Home/Safe layouts and hashes, reports counts in diagnostics and uses numbered selection for Science removal. It does not fully enumerate arbitrary Windows roots or enable whole-root or executable cleanup there. The earlier Windows whole-root entry point is disabled because a supported path and an empty `envs` directory do not establish root or cache ownership.

Total Remove on Ubuntu is deliberately limited to a root this installer created and sealed after verification, whose tree still matches. Other environments in the root, an unexpected file, other overlapping roots, mount points, external configuration/cache settings, active processes or unresolved root-specific shell integration block deletion. Existing roots without that proof are inspection-only for whole-root removal. The candidate preserves shared shell settings; it does not automatically rewrite unresolved root-specific shell integration or reseal a changed tree. The installer's usual Science-only and binary-only actions retain their independent checks. The total plan lists the root, verified external launchers and exact registry entries before the two literal confirmations; a partial failure has no automatic rollback.

During approved native package execution, the installer can show a roughly five-second heartbeat based on whether its child process is still active. It does not estimate a package count or completion percentage. Incomplete or oversized transaction output cannot count as a verified commit.

## Physical acceptance gate

Run on disposable or explicitly approved targets only. Keep the package plans and record the candidate commit. Do not publish v0.9.0 based on the local fixture tests.

| Host | Confirm before release |
|---|---|
| Iridium — Ubuntu 26.04 | Existing root, genuine original metadata, in-place migration, preserved third-party root/cache and other environments; separate binary and package approvals; Python, Spyder and first kernel; CPU PyTorch flow. |
| HP Z240 — Ubuntu 26.04 | New root defaults, saved configuration and optional selection; visible heartbeat; fresh install and update; Science-only removal and Total Remove rejection/success only on an approved disposable root. Check that a second root and an external environment remain untouched. |
| Niobium — Ubuntu 24.04 | Verify that the prior CUDA acceptance still applies to the new commit. Recheck existing update, package restrictions, launcher and CUDA runtime on the actual GPU. |
| Windows 11 | Verify the existing update and standalone launcher repair; test new-root/configuration prompts, heartbeat, numbered Science-only removal and fail-closed whole-root behavior using a disposable target. |

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
