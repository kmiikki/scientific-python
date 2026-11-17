# Science activation and Spyder sibling-import fix — v0.1.0

## Defect and correction

Ubuntu's managed Spyder/kernel support could load `science-manager.py` by file location while its ordinary sibling imports still relied on Python's global search path. From the user's home directory, this raised `ModuleNotFoundError: No module named 'science_integrity'`, even though that file existed alongside the manager. The original installed-style source reproduced this exact failure in a clean subprocess.

The installed `scientific-python-spyder.sh` activation hook calls `/usr/bin/python3 -I -B <support>/science-manager.py spyder-profile --root <root>`. Isolated Python intentionally excludes the script directory from its import path, so this also broke plain `micromamba activate science`. The usage-tracking hook calls `science_processes.py` directly and has no sibling-import dependency.

The fix resolves project dependencies relative to each module's `__file__`:

- `science-spyder-start.py` uses one small file-location loader for its manager, runtime and startup helpers.
- The manager's existing helper loader now also loads the integrity and configuration modules from the same bundle. Integrity verification still precedes loading the remaining helpers.
- Deferred runtime package/GUI checks obtain their configuration from that manager rather than importing a global `science_config`.
- The dynamically loaded installer resolves its integrity bootstrap by file location as well.

The activation hook keeps its `-I -B` isolation flags; neither the hook template nor the installed hooks need a `PYTHONPATH` workaround.

No project directory is added to `sys.path` or `PYTHONPATH`, and no project module is injected into or replaced in `sys.modules`. Already cached same-named modules from another checkout cannot override the selected bundle. The reviewed startup/fontconfig helpers and `spyder-acceptance.py` already load their project targets by absolute file location; the corrected downstream dependencies remove the same failure there. The config-location CLI is a normal script entry point, not a dynamically imported helper.

## Tests performed

| Check | Result |
|---|---|
| New isolated startup regression methods | 10/10 passed |
| Full Python unittest discovery | 26 passed; 1 skipped because PowerShell is unavailable |
| Original installed-style source, home working directory | Confirmed the reported `science_integrity` failure before the fix |
| New source and installed-style support, home/unrelated working directories | Passed; project import path unchanged |
| Cached foreign same-named modules and integrity-failure path | Passed; no foreign dependency or path/settings mutation |
| Isolated activation CLI and actual Micromamba activation/deactivation in a synthetic root | Passed from home and unrelated working directories; prior Spyder profile restored on deactivation |
| Managed shell launcher with a foreign active environment | Selected `science` prefix and its Python explicitly; cleared inherited Python path overrides |
| Real installed Science Python, temporary Spyder profile | Default interpreter enabled, custom interpreter disabled, executable set to Science Python |
| Real headless `spyder_kernels.console` from the user's home directory | Started and executed corrected manager/runtime imports; kernel Python and prefix were Science; FFmpeg/FFprobe resolved inside Science |
| Source/platform manifests, Bash/entry smoke and extracted release ZIP | Passed |

The headless kernel used the existing interpreter and packages read-only. Its profile, connection file, configuration, caches and logs were under RAM-backed `/tmp`. The real Spyder framework adds its own help-plugin utility directory during configuration import; the fix itself adds no import-path entries. Clean-process tests verify the project's path behavior independently of that upstream side effect.

Environment preservation was checked using environment-tree metadata and Conda record hashes, plus byte hashes for existing settings, launchers and installed support files. All 13 environments, including `science` and `py314-opencv5-cuda`, matched the pre-test inventory, as did installed support and launchers. Live Spyder/IPython profile and history files changed during the observation window, so blanket equality of those directories is not claimed. A file-system-call audit of the native test found no writes under the real home directory: its mutating file operations targeted only temporary files or devices. Existing user files were not restored or overwritten. This is scoped preservation evidence, not a full content rehash of every environment payload.

## Delivery and acceptance boundary

The fix is committed locally and included in the refreshed v0.1.0 source ZIP. Its immutable manifests are regenerated automatically as a maintainer action. No package selection, package versions or Windows code changed; Windows/PowerShell suites were not rerun for this Linux-only fix.

**The currently installed support directory and launcher were not replaced.** No existing environment was reinstalled or updated. The delivery writes only project sources and reports; it does not overwrite existing user settings. An existing installation must intentionally receive the corrected support files before its installed launcher uses this fix; this task does not silently deploy them or instruct a reinstall.

Full graphical Spyder startup and the first IPython console connected through that GUI remain native acceptance checks after deployment of the corrected support files. The headless kernel test does not certify the complete GUI workflow. No GitHub publication was performed.
