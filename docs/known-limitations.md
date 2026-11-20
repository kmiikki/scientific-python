# Known limitations

## Platform acceptance

On Ubuntu 24.04 LTS, v0.9.2 passed fresh installation and Science removal with and without CUDA PyTorch. NVIDIA CUDA GPU computation, USB camera testing and the native progress test also passed. Earlier Ubuntu update, Spyder, IPython and media results are recorded separately. See [current acceptance](testing.md#v092-ubuntu-2404-lts-acceptance) and [v0.9.0 evidence](testing.md#v090-ubuntu-2404-lts-acceptance).

An earlier Ubuntu 26.04.1 fresh installation succeeded in an existing root. The separate Linux Total Remove hotfix passed on two Ubuntu 26.04 LTS systems. This source integrates that behavior. Existing Science prefixes with missing receipts can be reviewed for adoption before an in-place update. See the [lifecycle verification](testing.md#v091-lifecycle-verification).

Native Windows 11 / Windows PowerShell 5.1 acceptance of the integrated v0.9.2 installer is pending. The progress and transaction tests ran under Linux PowerShell. Earlier Windows tests verified the standalone desktop and command-launcher repair. The Start-menu launcher needs separate verification. See [Windows acceptance scope](testing.md#windows-11-native-acceptance-pending).

The Windows OpenCV 5.1.0 test used HDF5 1.14.6. With that runtime the HDF5 2.2.0 `libver='latest'` sample failed to read with `bad version number for layout message`. Other HDF5 and scientific data operations passed in that run. Keep source samples read-only when checking compatibility.

## USB camera hardware

Camera acceptance applies to the tested devices and backends. DirectShow displays friendly names when the OpenCV backend supplies them. Fallback probing reports indexes within a fixed discovery budget. Backends can hide the cause of an access failure. In V4L2, one camera can appear as several nodes. See [camera testing](camera-testing.md) and the [historical camera records](testing.md#v091-camera-hardware-acceptance).

## Configuration and updates

- Six foundation requests must remain compatible with the qualified release policy.
- Missing defaults are offered only in an interactive terminal, default No; declined differences can be offered again. No unattended config-addition flag is included.
- There is one active per-user configuration per platform, not independent root profiles.
- Removing a request does not automatically uninstall its package. No Synchronize, package ownership or pending-retirement feature is included.
- Legacy native package-history restrictions may produce a solver conflict. Such conflicts stop; they are not bypassed by guessing old user intent.
- PyTorch selection is available during fresh installation, through **O — Configure optional packages and install/update**, or in the active JSON. The Ubuntu 24.04 LTS GPU result covers the tested build, GPU and driver. NVIDIA CUDA 13 minor-version compatibility may allow a newer runtime than the driver's reported CUDA minor version. Newer driver features and PTX JIT can still require a driver upgrade. GPU acceptance on Windows 11 and Ubuntu 26.04 remains pending. [NVIDIA CUDA compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html)
- Bleach/tinycss2 selection depends on the full solver result and upstream metadata. There is no new permanent Bleach or tinycss2 pin.

## Transaction boundaries

Approval binds the package identities and native inputs. A different native preflight/commit is rejected; there is no silent fallback to another online solution. The frozen update uses Micromamba's own solver against a local universe containing only the approved final identities.

This does not provide an atomic filesystem transaction or guaranteed automatic rollback. If native linking fails after commit starts, the environment can need repair. Earlier explicitly approved missing-file repairs may already have completed if a later main update is cancelled.

Windows missing-file repair is limited to the registered GTK payload checks inherited from the original workflow. It relinks identical approved archives and does not infer package ownership. An unexpected repair identity change stops instead of substituting another plan.

An older root can use the validated active configuration after interactive confirmation. If no configuration can be validated, restore the original package requests. A fresh default list would lose the existing preferences.

## Integrity scope

Manifests and pinned bootstrap hashes catch inconsistencies relative to the trusted source copy. A co-located manifest is not a digital signature and cannot authenticate a distribution if both scripts and manifests were replaced. Use a trusted distribution source.

## Troubleshooting and reporting

Use menu **D** to collect diagnostics. Include the OS version, PowerShell version on Windows, installer version, selected operation and exact failure message. For a transaction mismatch retain the reported approved-lock, locked-preflight and commit evidence.

Inspect diagnostics before sharing; remove credentials, private paths, channel secrets and project data. Never share your complete environment directory as a default troubleshooting step.

If package commit has started and fails, preserve logs and inspect the environment before retrying. Do not delete other environments or the Micromamba root to fix one Science installation.
