# Ubuntu installation

Scientific Python 0.9.2 targets Ubuntu 24.04 LTS and 26.04 LTS on x86-64. The installer requires Bash, Ubuntu's system Python 3 and an ASCII account name. Graphical launchers require a supported desktop session. See the [native acceptance results](testing.md#v092-ubuntu-2404-lts-acceptance).

## Optional USB camera test

Select **U — USB Camera Test (optional)** or run `bash linux/07-test-usb-camera.sh`. Ubuntu uses V4L2 and supports explicit video nodes and persistent `by-id` paths. Installation and ordinary validation can run without cameras. See [camera selection, live preview and diagnostics](camera-testing.md).

## Start

Extract the entire project folder with both `linux/` and `shared/`. Open a terminal there and run:

```bash
bash linux/00-menu.sh
```

### Main menu

```text
Scientific Python 0.9.2 (Ubuntu LTS)
====================================

1  Install/update Scientific Python
O  Configure optional packages and install/update
2  Remove Spyder settings
3  Remove Science environment
4  Remove Micromamba installed by Scientific Python
5  Total Remove – delete selected Micromamba directory and all contents
I  Info
D  Diagnostics
V  Validation only
U  USB Camera Test (optional)
C  Package configuration location
Q  Quit
Selection:
```

Choose **1 — Install/update Scientific Python**. Run as your ordinary user, without `sudo`.

| Layout | Intended use |
|---|---|
| Recommended: `~/micromamba` | New installation, easy-to-find environment and cache |
| XDG: `~/.local/share/mamba` | New installation using per-user application-data layout |
| Existing | Reuse a detected executable and root; preserve other environments |
| Custom | A dedicated writable directory selected by the user |

For an existing Scientific Python installation, retain its root with **Existing**. Executable ownership, paths, root state and current shell selection are checked. Any offered Micromamba promotion is a separate approved action. Do not select a new layout to bypass an unresolved old configuration.

## Review and install

The installer creates or migrates the active JSON before package changes. A new configuration contains 42 direct requests. When an existing configuration omits release defaults, **1 — Install/update Scientific Python** can offer to append them with separate approval. The default answer is No. See [configuration and migration](configuration.md).

The installer identifies `envs/science` independently of root ownership. If an old environment lacks a receipt, the installer first checks its legacy evidence. A selected prefix with a recognized Micromamba executable, readable Conda history, coherent package records and Python and Spyder may also be adopted after explicit review. Adoption authorizes the in-place update of that prefix. Package changes have their own approval. Archived V3 request recovery still uses the verified history. Conflicting paths or missing configuration produce recovery instructions.

A fresh Science installation offers **0 — No PyTorch (default)**, **1 — PyTorch CPU** and **2 — PyTorch NVIDIA CUDA**, including when you reuse a Micromamba directory after removing Science. Press Enter at `PyTorch [0]:` to select No PyTorch. **0** and **1** skip NVIDIA and CUDA checks. Selecting **2** checks for an NVIDIA device and lets the solver check driver and GPU compatibility. An ordinary update keeps the saved choice. Select **O — Configure optional packages and install/update** to change it before an update. See [optional PyTorch](configuration.md#optional-pytorch) for backups and removing a request.

The installer shows one **Current / Target** summary before Micromamba validation. Review the selected executable, Micromamba directory, Science environment, launcher locations and package changes. At `Apply these package changes? [y/N/full]:`, enter `full` to see the whole plan or `y` to apply it. The locked transaction stages verified archives and checks that Micromamba applies the approved package identities. Bootstrap downloads are checked against immutable release metadata. Incompatible dependencies or uncertain ownership stop the operation.

The default environment is `~/micromamba/envs/science`. The package manager resolves transitive dependencies automatically. No administrator rights are needed for the normal workflow.

### Installation progress

Step `[6/9] Installing packages` starts at `00:00` after approval. The same clock continues through archive preparation, Micromamba execution and Python verification. During longer operations it prints the current activity approximately every five seconds. Elapsed time measures time since approval, with no package completion estimate. This output is from the native progress test with simulated packages.

```text
[6/9] Installing packages  RUNNING  Elapsed: 00:00  Python: preparing approved transaction
[6/9] Installing packages  RUNNING  Elapsed: 00:05  Micromamba: applying approved transaction
[6/9] Installing packages  RUNNING  Elapsed: 00:10  Micromamba: applying approved transaction
[6/9] Installing packages  RUNNING  Elapsed: 00:15  Python: verifying installed packages and restoring metadata
[6/9] Installing packages  RUNNING  Elapsed: 00:20  Python: verifying installed packages and restoring metadata
[6/9] Installing packages              PASS
```

## Launch and verify

Open **Scientific Python - Spyder** from the application menu, or use `science-spyder` in a new terminal. Desktop shortcut support depends on the session; follow the installer instructions for trusting the shortcut or use the application menu.

The final summary reports `Installation status`, `Package installation`, `Automatic tests` and `Other environments`, followed by log and diagnostic paths. `User GUI acceptance : PENDING` means you still need to check the launcher, Spyder and its first IPython kernel for that installation. See the [current test results](testing.md#v092-ubuntu-2404-lts-acceptance) and [earlier Spyder and runtime acceptance](testing.md#v090-ubuntu-2404-lts-acceptance).

## Configuration and maintenance

The usual JSON path is `~/.config/scientific-python/science-release.json`; `XDG_CONFIG_HOME` takes precedence when configured. Menu **C** shows the location. See [configuration](configuration.md).

**2 — Remove Spyder settings** is separate from environment removal. Use **I — Info** to inspect the detected setup, **D — Diagnostics** for a report and **V — Validation only** to run runtime checks without changing packages.

### 3 — Remove Science environment

Close Spyder and its kernels, and deactivate Science in any active shells. Check the `Selected environment:` path. Enter `y` at `Remove Science environment and its shortcuts? [y/N]:` to remove the selected `envs/science`, its managed launchers and its registration. Enter or `n` prints `Science removal cancelled.` and returns to the menu.

The installer checks ownership, mount boundaries, links and active processes. Other environments, Micromamba, shared caches and the active per-user package configuration are preserved. Verification checks sibling environment entries and the top level of the package cache, avoiding recursive scans of unrelated payloads. `Removal result: PASS` reports success. For `FAIL` or `BLOCKED`, use the displayed log and report paths.

### 4 — Remove Micromamba installed by Scientific Python

This removes only the verified installer-owned executable in the **Recommended** `~/micromamba` directory. The installer stops if environments remain, registrations point outside the directory, or it cannot establish ownership and exclusive use. It displays `Micromamba executable:` and `Micromamba directory:` with their exact paths.

Confirm at `Remove this Micromamba executable? [y/N]:`. Enter or `n` returns to the menu with `Micromamba removal cancelled.` as the result. `The Micromamba executable was removed.` confirms success. The directory, caches, launchers and settings are preserved.

### 5 — Total Remove

`Selected Micromamba directory:` shows the target. `The selected directory and its entire contents will be deleted.` applies to every environment, cache and user file inside it. An independently identifiable Micromamba directory can qualify even when it contains no Science environment. The installer preserves other directories, external launchers and Bash settings. It previews any registrations for the selected directory that it will remove.

Use an interactive terminal. Type the exact path for a non-default directory, then type `Yes, I do understand.` at both confirmations. If you decline, the menu reports `Cancelled. Nothing was removed.` before returning. Mount points, links leaving the directory, shared resources, active use, insufficient permissions and changed targets stop removal. This operation is separate from the [Ubuntu 24.04 LTS Science removal tests](testing.md#v092-ubuntu-2404-lts-acceptance).
