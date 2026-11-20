# Windows 11 installation

Scientific Python 0.9.2 targets Windows 11 x86-64 with Windows PowerShell 5.1. Native acceptance of the integrated 0.9.2 installer is pending. See [platform limitations](known-limitations.md#platform-acceptance).

## Optional USB camera test

Select **U — USB Camera Test (optional)** or run `windows/07-TEST-USB-CAMERA.cmd`. The test uses DirectShow in the selected Home or Safe installation. Installation and ordinary validation can run without cameras. See [command-line selection, live preview and diagnostics](camera-testing.md).

## Start

Keep `windows/` and `shared/` in the same extracted project folder. Double-click `windows/00-START-HERE.cmd`; it starts Windows PowerShell with a process-scoped execution-policy bypass. It does not require Python to validate configuration.

### Main menu

This example uses a machine with neither layout installed. Status and paths depend on the Windows account and the detected installation.

```text
Scientific Python 0.9.2 (Windows 11)
====================================

Current status
--------------
Windows long paths : enabled
Home root          : C:\Users\<username>\micromamba
     micromamba      : not installed
     science         : science not installed
     Spyder launcher : not installed
Safe root          : C:\micromamba\u-<user-id>
     micromamba      : not installed
     science         : science not installed
     Spyder launcher : not installed
Spyder settings    : not found

Choose an action:

  1  Install/update Scientific Python
  O  Configure optional packages and install/update

  2  Apply/repair the OpenCL patch
  3  Show OpenCL patch status

  4  Remove Spyder user settings
  5  Remove Science environment
  M  Remove Micromamba installed by Scientific Python
  6  Total Remove – delete selected Micromamba directory and all contents

  U  USB Camera Test (optional)
  D  Diagnostics (redacted)
  I  Info
  Q  Quit

Package configuration: C:\Users\<username>\AppData\Local\ScientificPython\science-release.json
Selection:
```

Choose **1 — Install/update Scientific Python**. Auto detects or offers a supported layout.

| Layout | Root | Micromamba executable |
|---|---|---|
| Home | `%USERPROFILE%\micromamba` | `%LOCALAPPDATA%\micromamba\micromamba.exe` |
| Safe | Dedicated `C:\micromamba\u-<user-id>` | `<root>\bin\micromamba.exe` |

The Science prefix is always `<root>\envs\science`. Use the same normal Windows account throughout. Preparation checks Windows long-path support and permissions; a required machine setting or Safe-layout permission setup may show a UAC prompt. Follow any restart instruction and run option 1 again. Do not run the entire workflow under a different administrator account.

Migration validates the selected package configuration before preparation. You can explicitly associate a validated active configuration with an older Science prefix and adopt that prefix for update when readable Conda, Python and Spyder evidence identifies it. The package plan still requires its own approval. For legacy JSON without a package list, supply the original JSON and its corresponding `science-release.ps1` together.

## Review and install

The installer verifies the pinned Micromamba 2.10.0 executable, reads your active JSON, resolves dependencies and displays package actions, old/new versions and builds, source channels and an available download estimate. Approval is tied to the displayed plan's SHA256 identity.

A fresh Science installation offers **0 — No PyTorch (default)**, **1 — PyTorch CPU** and **2 — PyTorch NVIDIA CUDA**. Press Enter at `PyTorch [0]:` to select No PyTorch. **0** and **1** skip NVIDIA and CUDA checks. Use **O — Configure optional packages and install/update** to change a saved choice before an update. See [optional PyTorch](configuration.md#optional-pytorch) for selection and compatibility details.

If eligible dependency packages will disappear, review them at `Remove exactly these dependency packages? [y/N]:`. The full plan has its own `Apply exactly this transaction? [y/N]:` confirmation. After approval, the installer verifies archives and executes the approved package identities offline. A change to those identities, the configuration, the executable, the lock, staged inputs or installed metadata stops the operation. Necessary missing-file repairs are separately reviewed, same-identity relink transactions before the main update's solve and approval.

Leave the terminal open until automatic checks finish. A failed or interrupted package commit may require diagnosis; automatic rollback is not guaranteed. Transaction evidence is kept in the reported `<root>\tmp\science-transaction-…` directory.

### Installation progress

Step `[6/9] Installing packages` starts at `00:00` after approval. One elapsed clock covers archive preparation, Micromamba operations and PowerShell verification. Progress continues approximately every five seconds during prolonged work, including verification after the child process exits. The time is elapsed duration, with no package completion estimate. This output was captured with a simulated child process under Linux PowerShell.

```text
[6/9] Installing packages  RUNNING  Elapsed: 00:00  PowerShell: preparing approved transaction
[6/9] Installing packages  RUNNING  Elapsed: 00:05  Micromamba: applying approved transaction
[6/9] Installing packages  RUNNING  Elapsed: 00:10  PowerShell: processing and verifying Micromamba results
```

## Launch Spyder

After `Scientific Python installation/update completed successfully.`, close PowerShell windows opened during setup. Double-click **Scientific Python science - Spyder** on the desktop. The command launcher is `<layout-bin>\science-spyder.cmd`. A new terminal can find it after PATH setup.

The launcher targets the selected Science environment and applies the managed OpenCL/GTK-related setup. Validate the first Spyder startup and IPython kernel on the actual Windows machine; passing installer checks does not replace this development-release acceptance step.

## Customize, diagnose and remove

- Active configuration: `%LOCALAPPDATA%\ScientificPython\science-release.json`. Edit its `ScientificPackages` list; see [configuration](configuration.md).
- **D — Diagnostics (redacted)** collects a diagnostic report. Inspect it before sharing.
- **2 — Apply/repair the OpenCL patch** and **3 — Show OpenCL patch status** apply and inspect the Spyder/OpenCV activation patch.
- **4 — Remove Spyder user settings** handles account-wide Spyder settings separately from Science removal.

Close Science processes and deactivate the environment before changing it. When both Home and Safe exist, verify the selected path.

### 5 — Remove Science environment

This removes the selected `envs\science` and its managed shortcuts after a matching ownership marker and an active-use check. The installer prints `Selected environment:` immediately before `Remove Science environment and its shortcuts? [y/N]:`. Enter or `n` prints `Science removal cancelled.` and returns normally. `The science environment was removed.` confirms success. Micromamba, other environments, the cache and the per-user configuration are preserved.

### M — Remove Micromamba installed by Scientific Python

This removes only the executable. It requires a matching signature recorded by the installer when it placed that executable. An older or externally supplied binary without that evidence is preserved. The installer also rejects shared executables and active use.

Check the exact paths under `Micromamba executable:` and `Micromamba directory:`. Enter or `n` at `Remove this Micromamba executable? [y/N]:` returns to the menu with `Micromamba removal cancelled.` as the result. `The Micromamba executable was removed.` confirms success. Environments, caches and the selected directory remain in place.

### 6 — Total Remove

`Selected Micromamba directory:` shows the target. `The selected directory and its entire contents will be deleted.` applies to all environments, caches and user files within it. The directory must be a verified local NTFS Micromamba layout. The Home layout's external executable and other files outside the selected directory are preserved. The installer previews matching settings and registrations it will clear.

Use an interactive console. Type the exact path for a non-default directory, then type `Yes, I do understand.` at both confirmations. If you decline, the menu reports `Cancelled. Nothing was removed.` before returning. The installer checks for shared resources, junctions and other reparse points, active use, effective deletion rights and changes since approval. The report uses `SUCCESS`, `BLOCKED` or `PARTIAL` for an attempted removal.

## Interrupted installation and removal

If a native transaction finished and later setup stopped, keep the transaction evidence under the selected root's temporary directory. Run **1 — Install/update Scientific Python** again with the same configuration. When the installed identities match an approved transaction, the installer can resume verification and finish state, OpenCL and launcher setup after approval. Temporary or missing conda-forge package URLs require an exact version, build, subdirectory and SHA-256 match to repository metadata. Inspect the specific failure if a source cannot be verified.

## Windows 11 acceptance

See the [0.9.2 acceptance record](testing.md#v092-ubuntu-2404-lts-acceptance) for automated results and the remaining [Windows native checks](testing.md#windows-11-native-acceptance-pending).
