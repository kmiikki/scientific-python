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
- **6 — Remove Micromamba:** a separate, broader operation with additional checks and confirmation. Do not use it to remove only Science.

Close Science processes and deactivate the environment before changing it. If multiple supported layouts exist, verify the selected path in the menu. Other environments are never an implied removal target.
