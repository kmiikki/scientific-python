# Known limitations

## Acceptance pending

The user has reported successful base Ubuntu 24.04 installation, Spyder/kernel and launcher acceptance. The [release-default addition follow-up](release-package-upgrade.md#final-ubuntu-2404-acceptance) still requires a manual seven-package update/import check. Earlier unaccepted items below describe the initial preparation evidence, not a claim that this user test was never performed.

The source targets Ubuntu 24.04 LTS, Ubuntu 26.04 LTS and Windows 11 x86-64. Native Ubuntu 26.04 and Windows 11/PowerShell 5.1 installation, removal, GUI/kernel and media acceptance remain pending. The current opt-in seven-package update requires its own Ubuntu 24.04 acceptance even though the user has already accepted the base environment.

PowerShell 7.4.6 tests on Linux establish parser/helper and package-execution contract behavior. They do not establish native Windows filesystem, UAC, DLL, hook or PowerShell 5.1 acceptance. The native Micromamba contract tests install only inert synthetic noarch packages in temporary directories, with Windows target selection. They do not run Windows binaries on Linux.

The [Spyder startup follow-up](spyder-startup-fix.md) passed a real headless Science kernel and temporary-profile interpreter configuration check. It does not certify GUI startup or the GUI-connected first console. This source-only delivery leaves existing installed support files unchanged.

## Configuration and updates

- Six foundation requests must remain compatible with the qualified release policy.
- Missing defaults are offered only in an interactive terminal, default No; declined differences can be offered again. No unattended config-addition flag is included.
- There is one active per-user configuration per platform, not independent root profiles.
- Removing a request does not automatically uninstall its package. No Synchronize, package ownership or pending-retirement feature is included.
- Legacy native package-history restrictions may produce a solver conflict. Such conflicts stop; they are not bypassed by guessing old user intent.
- Optional PyTorch/torchvision/LightGBM/Pingouin combinations and CUDA support have not all been tested. No new broad solver matrix was run for release preparation.
- Bleach/tinycss2 selection depends on the full solver result and upstream metadata. There is no new permanent Bleach or tinycss2 pin.

## Transaction boundaries

Approval binds the package identities and native inputs. A different native preflight/commit is rejected; there is no silent fallback to another online solution. The frozen update uses Micromamba's own solver against a local universe containing only the approved final identities.

This does not provide an atomic filesystem transaction or guaranteed automatic rollback. If native linking fails after commit starts, the environment can need repair. Earlier explicitly approved missing-file repairs may already have completed if a later main update is cancelled.

Windows missing-file repair is limited to the registered GTK payload checks inherited from the original workflow. It relinks identical approved archives and does not infer package ownership. An unexpected repair identity change stops instead of substituting another plan.

A missing or inconsistent old configuration stops migration. Keep the original files and obtain the corresponding old package-list source before continuing. Do not substitute defaults for an uncertain old environment.

## Integrity scope

Manifests and pinned bootstrap hashes catch inconsistencies relative to the trusted source copy. A co-located manifest is not a digital signature and cannot authenticate a distribution if both scripts and manifests were replaced. Use a trusted distribution source.

## Troubleshooting and reporting

Use **D — Diagnostics** from the relevant menu. Include OS and PowerShell versions, installer version, selected operation and the exact failure message. For a transaction mismatch retain the reported approved-lock, locked-preflight and commit evidence.

Inspect diagnostics before sharing; remove credentials, private paths, channel secrets and project data. Never share your complete environment directory as a default troubleshooting step.

If package commit has started and fails, preserve logs and inspect the environment before retrying. Do not delete other environments or the Micromamba root to fix one Science installation.
