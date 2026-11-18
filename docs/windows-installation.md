# Windows 11 installation

Target: Windows 11 x86-64 and Windows PowerShell 5.1. Native acceptance is pending; read [limitations](known-limitations.md).

## Start

Keep `windows/` and `shared/` in the same extracted project folder. Double-click `windows/00-START-HERE.cmd`; it starts Windows PowerShell with a process-scoped execution-policy bypass. It does not require Python to validate configuration.

Choose **1 — Install/update**. Auto detects or offers a supported layout:

| Layout | Root | Micromamba executable |
|---|---|---|
| Home | `%USERPROFILE%\micromamba` | `%LOCALAPPDATA%\micromamba\micromamba.exe` |
| Safe | Dedicated `C:\micromamba\u-<user-id>` | `<root>\bin\micromamba.exe` |

The Science prefix is always `<root>\envs\science`. Use the same normal Windows account throughout. Preparation checks Windows long-path support and permissions; a required machine setting or Safe-layout permission setup may show a UAC prompt. Follow any restart instruction and run option 1 again. Do not run the entire workflow under a different administrator account.

Migration validation precedes preparation. An uncertain existing configuration stops the operation without changing the original files or Science environment. For legacy JSON without a package list, supply the original JSON and its corresponding `science-release.ps1` together. A completely new installation does not need legacy files.

## Review and install

The installer verifies the pinned Micromamba 2.10.0 executable, reads your active JSON, resolves dependencies and displays package actions, old/new versions and builds, source channels and an available download estimate. Approval is tied to the displayed plan's SHA256 identity.

After approval, archives are verified and staged. Native execution uses only frozen offline inputs. Any different LINK/UNLINK identity, changed configuration, executable, lock, staged input or installed metadata stops the operation. It does not approve another online solution for you. Necessary missing-file repairs are separately reviewed, same-identity relink transactions before the main update's solve and approval.

Leave the terminal open until automatic checks finish. A failed or interrupted package commit may require diagnosis; automatic rollback is not guaranteed. Transaction evidence is kept in the reported `<root>\tmp\science-transaction-…` directory.

## Launch Spyder

After success, close PowerShell windows opened during setup. Double-click **Scientific Python science - Spyder** on the desktop. The command launcher is `<layout-bin>\science-spyder.cmd`; a new terminal can find it after PATH setup.

The launcher targets the selected Science environment and applies the managed OpenCL/GTK-related setup. Validate the first Spyder startup and IPython kernel on the actual Windows machine; passing installer checks does not replace this development-release acceptance step.

## Customize, diagnose and remove

- Active configuration: `%LOCALAPPDATA%\ScientificPython\science-release.json`. Edit its `ScientificPackages` list; see [configuration](configuration.md).
- **D — Diagnostics:** collect a diagnostic report. Inspect it before sharing.
- **2 — Remove Spyder settings:** removes selected user settings after confirmation.
- **5 — Remove science:** confirms the supported Science target and preserves the Micromamba installation and other environments.
- **6 — Whole-root Micromamba removal status:** this action is blocked in the candidate. Windows root and cache exclusivity are not yet verified. No executable, root, cache or user settings are removed by this action.

Close Science processes and deactivate the environment before changing it. If multiple supported layouts exist, verify the selected path in the menu. Other environments are never an implied removal target.


## Interrupted installation and removal

If a native transaction finished and later setup stopped, keep the transaction evidence under the selected root's temporary directory. Run **Install/update** again with the same configuration. When the installed identities match an approved transaction, the installer can resume verification and finish state, OpenCL and launcher setup after approval. Temporary or missing conda-forge package URLs require an exact version, build, subdirectory and SHA-256 match to repository metadata. Inspect the specific failure if a source cannot be verified.

Use **Remove science** after a successful installer finalization. It requires the matching prefix ownership marker and explicit approval. It removes the selected Science environment and its launchers while keeping the Micromamba root and every other environment. A legacy environment with insufficient evidence is preserved.

## Windows 11 acceptance

Use the ZIP generated from the recorded candidate commit. Verify the existing environment's update and no-op paths first. On a separately approved disposable root, test fresh installation, interruption after native commit, recovery without package changes and Science-only removal with a second environment present. Test the desktop shortcut, `science-spyder`, the Start-menu entry if present, the first Spyder console, OpenCV/FFV1 and the HDF5 compatibility sample. Choose **O — Configure optional packages and install/update** to test CPU or CUDA PyTorch, then review and approve the solver plan.
