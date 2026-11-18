# Known limitations

## Platform acceptance

Niobium passed the Ubuntu 24.04 update of the existing Science environment, Spyder GUI and IPython, media checks, and PyTorch CUDA installation and computation. Fresh installation and removal for the current snapshot remain outside that acceptance. See the [native test results](testing.md#niobium-native-acceptance).

The earlier HP Z240 Ubuntu 26.04.1 fresh installation succeeded in an existing root. The updated ownership path still needs native acceptance on that machine. The iridium evidence contains a completed state and installed package inventory. Its collected environment ownership receipt is missing, so update and removal remain blocked until matching environment-specific proof is available.

Windows 11 acceptance of the integrated installer, including recovery, OpenCL and launcher behavior, is pending. Earlier Windows testing verified the standalone desktop and command-launcher repair. The Start-menu launcher needs separate verification. Linux PowerShell and inert Micromamba fixtures cover the transaction contract and helper logic.

The Windows OpenCV 5.1.0 test used HDF5 1.14.6. With that runtime the HDF5 2.2.0 `libver='latest'` sample failed to read with `bad version number for layout message`. Other HDF5 and scientific data operations passed in that run. Keep source samples read-only when checking compatibility.

## Configuration and updates

- Six foundation requests must remain compatible with the qualified release policy.
- Missing defaults are offered only in an interactive terminal, default No; declined differences can be offered again. No unattended config-addition flag is included.
- There is one active per-user configuration per platform, not independent root profiles.
- Removing a request does not automatically uninstall its package. No Synchronize, package ownership or pending-retirement feature is included.
- Legacy native package-history restrictions may produce a solver conflict. Such conflicts stop; they are not bypassed by guessing old user intent.
- Optional PyTorch is requested through **Optional packages** or the advanced configuration. Niobium passed installation and a GPU matrix multiplication using NVIDIA CUDA 13 minor-version compatibility. The installer reported CUDA 13.5 dependency compatibility and PyTorch reported CUDA 13.4. This result covers the tested GPU and driver. Newer driver features and PTX JIT can still require a driver upgrade. GPU acceptance on Windows 11 and Ubuntu 26.04 remains pending. [NVIDIA CUDA compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html)
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
