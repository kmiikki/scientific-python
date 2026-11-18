# Ubuntu installation

Targets: Ubuntu 24.04 LTS and 26.04 LTS, x86-64. Native reinstall/startup acceptance is pending. The installer requires Bash, Ubuntu's system Python 3 and a supported desktop session for graphical launchers. The current platform check requires an ASCII account name.

## Start

Extract the entire project folder with both `linux/` and `shared/`. Open a terminal there and run:

```bash
bash linux/00-menu.sh
```

Choose **1 — Install/update**. Run as your ordinary user, without `sudo`.

| Layout | Intended use |
|---|---|
| Recommended: `~/micromamba` | New installation, easy-to-find environment and cache |
| XDG: `~/.local/share/mamba` | New installation using per-user application-data layout |
| Existing | Reuse a detected executable and root; preserve other environments |
| Custom | A dedicated writable directory selected by the user |

For an existing Scientific Python installation, retain its root with **Existing**. Executable ownership, paths, root state and current shell selection are checked. Any offered Micromamba promotion is a separate approved action. Do not select a new layout to bypass an unresolved old configuration.

## Review and install

The active JSON is created or safely migrated before package changes. A new configuration contains 42 direct requests. An existing user configuration is preserved and is not merged with new defaults.

The installer verifies ownership of `envs/science` independently of the Micromamba root. An Existing installation can manage its own Science environment while preserving the root and other environments. For an older installation missing the in-prefix marker, the installer checks the environment receipt, directory identity, completed installer state and installed package fingerprint. If the environment receipt is missing or the evidence disagrees, the installer preserves the environment and reports the missing proof.

Review the selected executable, root, Science prefix, launcher locations and resolved package changes. After approval the existing locked transaction path stages verified archives and compares native preflight/commit identities. Bootstrap downloads are checked against immutable release metadata. Incompatible dependencies or uncertain ownership stop the operation.

The default environment is `~/micromamba/envs/science`. The package manager resolves transitive dependencies automatically. No administrator rights are needed for the normal workflow.

## Launch and verify

Open **Scientific Python - Spyder** from the application menu, or use `science-spyder` in a new terminal. Desktop shortcut support depends on the session; follow the installer instructions for trusting the shortcut or use the application menu.

For development-release acceptance, open the first IPython kernel and check numerical, image/video and new-package imports. Launcher persistence after signing out and back in is a separate manual check. These tests have not yet been marked accepted on Ubuntu 24.04 or 26.04.

## Configuration and maintenance

The usual JSON path is `~/.config/scientific-python/science-release.json`; `XDG_CONFIG_HOME` takes precedence when configured. Menu **C** shows the location. See [configuration](configuration.md).

The menu also provides:

- **2 — Remove Spyder settings:** separate from environment removal.
- **3 — Remove science:** validates the selected Science target and ownership, confirms removal and protects other environments.
- **4 — Remove owned Micromamba:** separate executable removal; the menu explicitly describes preservation of root/cache. Use Science removal when only the environment should go.
- **I — Info**, **D — Diagnostics**, **V — Validation only**.

Close Spyder, kernels and active Science shells before removal/update. Read the target path before confirming. A supervised remove/install acceptance test must preserve all other environments.


## Ubuntu 26.04 acceptance

After the approved `main` update, use **Code → Download ZIP** and record the commit being tested. On the HP Z240, check update, runtime imports, the launchers and Spyder's first console. Run removal and fresh-install verification against an explicitly approved test target with another environment present.

On iridium, select **Existing** and verify the root, the Science prefix and the ownership evidence first. If the environment receipt is unavailable or conflicts with the directory identity, record that diagnostic and preserve the existing installation. Run the update only when ownership checks pass. Choose **O — Optional packages → PyTorch CPU**, then review and approve the solver plan to test the optional workflow.
