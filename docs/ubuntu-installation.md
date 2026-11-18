# Ubuntu installation

Targets: Ubuntu 24.04 LTS and 26.04 LTS, x86-64. The existing-environment update and Spyder startup passed on Niobium with Ubuntu 24.04. Fresh-install and removal acceptance for the current snapshot are pending. The installer requires Bash, Ubuntu's system Python 3 and a supported desktop session for graphical launchers. The current platform check requires an ASCII account name.

## Start

Extract the entire project folder with both `linux/` and `shared/`. Open a terminal there and run:

```bash
bash linux/00-menu.sh
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

The active JSON is created or safely migrated before package changes. A new configuration contains 42 direct requests. An existing user configuration is preserved and is not merged with new defaults.

The installer verifies ownership of `envs/science` independently of the Micromamba root. When the environment receipt is missing, the migration checks a supported completed installer state, directory ownership and identity, package records and Conda history. For the archived Ubuntu V3 home layout it also checks the original launcher and exact historical package command. V3 configuration recovery has its own approval and is limited to the verified archived requests; restore the original configuration if extra requests are found. When the evidence is sufficient, an approved migration creates an environment receipt for updates only. It does not grant ownership of the executable, cache or root. If evidence is unavailable or inconsistent, the installer preserves the environment and identifies what to recover.

For a new root the installer shows whether release defaults or a saved configuration will be used. A reset requires separate approval and a byte-for-byte backup; it is unavailable when another installation may share the configuration. Choose **O — Configure optional packages and install/update** to select CPU or CUDA PyTorch and continue directly to the separate transaction review. Removing the PyTorch request edits only the configuration.

Review the selected executable, root, Science prefix, launcher locations and resolved package changes. After approval the existing locked transaction path stages verified archives and compares native preflight/commit identities. Bootstrap downloads are checked against immutable release metadata. Incompatible dependencies or uncertain ownership stop the operation.

The default environment is `~/micromamba/envs/science`. The package manager resolves transitive dependencies automatically. No administrator rights are needed for the normal workflow.

## Launch and verify

Open **Scientific Python - Spyder** from the application menu, or use `science-spyder` in a new terminal. Desktop shortcut support depends on the session; follow the installer instructions for trusting the shortcut or use the application menu.

For development-release acceptance, open the first IPython kernel and check numerical, image/video and new-package imports. Launcher persistence after signing out and back in is a separate manual check. Spyder GUI, the IPython kernel and the scientific runtime checks passed on Niobium with Ubuntu 24.04. Native acceptance on Ubuntu 26.04 is pending. See [native acceptance results](testing.md#niobium-native-acceptance).

## Configuration and maintenance

The usual JSON path is `~/.config/scientific-python/science-release.json`; `XDG_CONFIG_HOME` takes precedence when configured. Menu **C** shows the location. See [configuration](configuration.md).

The menu also provides:

- **2 — Remove Spyder settings:** separate from environment removal.
- **3 — Remove science:** validates the selected Science target and ownership, confirms removal and protects other environments.
- **4 — Remove owned Micromamba:** separate executable removal; the menu explicitly describes preservation of root/cache. Use Science removal when only the environment should go.
- **5 — Total Remove:** distinct from Science and executable removal. Available only for a newly provisioned root with independently verified exclusivity and an unchanged inventory. Review the full scope and type the exact requested confirmations. A root with unknown contents, external caches or unresolved shell integration is blocked.
- **I — Info**, **D — Diagnostics**, **V — Validation only**.

Close Spyder, kernels and active Science shells before removal/update. Read the target path before confirming. A supervised remove/install acceptance test must preserve all other environments.


## Ubuntu 26.04 acceptance

Test a ZIP generated from the recorded candidate commit. See the [candidate checklist](iridium-migration-candidate.md). On the HP Z240, check update, runtime imports, the launchers and Spyder's first console. Run removal and fresh-install verification against an explicitly approved test target with another environment present.

On Iridium, select **Existing** and verify the root, the Science prefix and the ownership evidence first. Run the update only when ownership and configuration provenance checks pass. Choose **O — Configure optional packages and install/update → PyTorch CPU**, then review and approve the solver plan to test the optional workflow.
