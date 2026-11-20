# Package configuration and migration

To change the package selection, edit only the active JSON's **`ScientificPackages` list**, save it and select **1 — Install/update Scientific Python**. You do not need a command line, checksum calculator, manifest editor or dependency list.

## Active file

| Platform | Location |
|---|---|
| Ubuntu | `$XDG_CONFIG_HOME/scientific-python/science-release.json`, normally `~/.config/scientific-python/science-release.json` |
| Windows | `%LOCALAPPDATA%\ScientificPython\science-release.json` |

This per-user file remains outside the extracted installer. Updating source files does not overwrite it. A user has one active configuration per platform; selecting another root does not create an independent package profile.

The document has exactly three keys: `SchemaVersion` (currently `1`), `Channels` and `ScientificPackages`. Ordinary customization changes only the last list. The [default document](../shared/science-release.default.json) is a complete example; the [schema](../shared/science-release.schema.json) describes the structure.

## Editing requests

Each list item requests one package. Examples of individual items:

```json
"pingouin"
```

```json
"numpy>=2,<3"
```

```json
"pytorch[build='cpu*']"
```

Add `"pingouin"` as another comma-separated item to request it. Replace an existing `"numpy"` item when adding its version restriction; do not keep both. Removing `"seaborn"` stops requesting it. Seaborn, Xarray, Statsmodels, Numba and SymPy are already included in new defaults.

### Optional PyTorch

A fresh installation on Ubuntu or Windows prints `Configured PyTorch backend:` and offers **0 — No PyTorch (default)**, **1 — PyTorch CPU**, **2 — PyTorch NVIDIA CUDA** and **Q — Back**. Press Enter at `PyTorch [0]:` to choose No PyTorch. The installer prints `No PyTorch selected.`, `PyTorch CPU selected.` or `PyTorch CUDA selected.` before continuing to the next installation step.

Use **O — Configure optional packages and install/update** to change a saved choice. No PyTorch and CPU skip PyTorch GPU and driver checks. Selecting CUDA checks for an NVIDIA device. Installation or update with a saved CUDA request verifies compatibility during dependency resolution. The installer saves the selected build constraint in the active JSON. Review the proposed package changes and approve the transaction to install. A declined transaction leaves the selection saved for the next run.

For an existing environment, choose **R — Remove the PyTorch request** and approve `Remove the configuration request only? [y/N]:`. The installer prints `PyTorch is no longer requested. Installed packages were preserved.` and returns to the menu. A changed selection saves the previous configuration as `science-release.optional-<SHA-256>.json` in the configuration directory. Selecting the same backend again leaves the configuration bytes and backup history intact.

Advanced users can still edit JSON. For example, `"pytorch[version='>=2.13,<3',build='cpu*']"` selects a CPU build within a version range. Plain `"pytorch"` lets Micromamba select the variant. The menu retains version and channel constraints and refuses to overwrite a specific build pin that conflicts with the new backend.

The runtime report records the backend and checks CPU matrix multiplication and autograd. With a working CUDA backend it also verifies the device name and capability, GPU matrix multiplication, CPU–GPU transfers and CUDA synchronization. Native Ubuntu 24.04 LTS installation and GPU execution passed with v0.9.2 and PyTorch 2.13.0. See the [acceptance record](testing.md#v092-ubuntu-2404-lts-acceptance) and [CUDA limitations](known-limitations.md#configuration-and-updates).

For CUDA, the installer verifies the NVIDIA driver and the lowest compute capability reported by the GPUs. It checks `__cuda` and `__cuda_arch` through Micromamba. If the installed Toolkit masks the driver capability, the verified driver value is passed only to the installer’s Micromamba subprocesses. A verified architecture override is passed only if Micromamba reports the matching virtual package after probing it. Micromamba 2.10.0 ignores that architecture override. The installer checks the minimum declared by conda-forge’s selected `cuda-arch` package in the resolved plan.

The solver first seeks a CUDA runtime no newer than the driver’s reported CUDA minor version. For CUDA 13 on an NVIDIA R580-or-newer driver, a CUDA-version dependency conflict can trigger a second solve within CUDA 13. The installer checks the conda-forge runtime metadata, preserves the other package constraints and shows the minor-version compatibility caveat before approval.

For a CUDA installation, select **2 — PyTorch NVIDIA CUDA** in the fresh-install menu or through **O**. Review the resolved plan before approving. Check `backend: "cuda"`, the device name and compute capability in the runtime report alongside the scientific checks.

Torchvision, LightGBM and Pingouin are also optional. Torchvision can bring PyTorch as a dependency. A fresh No PyTorch installation stops before approval if the solver selects PyTorch through another request.

Keep valid JSON: double-quoted strings, commas between items and no trailing comma or comments. Duplicate package names and conflicting repeated requests are rejected. The installer accepts named Conda MatchSpecs; Micromamba performs final dependency and MatchSpec semantic validation.

The current workflow requires six compatible foundation requests: `python`, `python_abi`, `spyder`, `apache-arrow-proc`, `opencv`, `ffmpeg`. Preserve Python 3.14 GIL, Spyder 6.1.8, CPU Arrow, OpenCV 5.x Qt6 and FFmpeg 9.x GPL. Windows's FFmpeg floor is 9.0.1; Ubuntu's is 9.0.2. Existing higher media versions cannot be downgraded. Incompatible edits stop before package commit and leave the configuration available for correction.

## What removing a request means

Install/update does not automatically remove an installed package because its name disappeared from JSON. It may still be a dependency, or an independently installed user package. Automatic synchronization, ownership tracking and dependency retirement are not implemented in this release. The Windows path requires separate approval for eligible obsolete dependencies and protects direct, pinned and protected requests.

## Adding release defaults to an existing configuration

Interactive Install/update proposes current default package names absent from your active list, including any deliberately omitted defaults. The default is **No**. Approval appends only the displayed requests; versions/builds of existing requests, user additions and channel order remain unchanged. Declining preserves the original bytes and timestamp. Non-interactive runs do not prompt or modify the file. There is no new unattended opt-in flag.

A clean installation already has 42 requests. An older 35-request configuration is offered SHAP, PyWavelets, Optuna, Plotly, Hypothesis, Polars and XGBoost. Configuration approval is followed by a separate native package-event review. Declining permits success against the effective user configuration, with release-default differences reported independently. See [upgrade safety, reporting and acceptance](release-package-upgrade.md).

This is an additive configuration proposal, not environment synchronization or automatic dependency removal. Normal migration still preserves the original list without silently merging new defaults.

## Channels and integrity

Advanced users may change the ordered `Channels` array. Only configured channels are used for the initial solve; ambient rc channels are excluded. Channel-qualified requests must refer to a configured channel. Compatibility of additional channels is not guaranteed.

Your editable JSON is **excluded from fixed SHA256 manifests**. It receives UTF-8, syntax, duplicate-key, schema and request validation. The installer computes any hashes needed for approval automatically. Code, schema, default templates and bootstrap metadata remain covered by immutable installer manifests. Maintainers regenerate those manifests after source changes; users never do.

## Migration rules

1. An already valid active schema-v1 JSON is kept byte-for-byte, including its timestamp. Repeating migration is idempotent.
2. The installer searches the installer folder and the selected root's support location for prior configuration. Ubuntu uses `<root>/share/scientific-python/science-release.json` to recover configuration for an existing Science prefix. Windows uses `<root>/science-release.json` for the same purpose. A fresh installation with no active file starts from release defaults. If the active file validates and the prior file differs or is missing, an interactive install/update can associate the active file with the selected root after confirmation.
3. Existing user additions, removals, channels, versions and build restrictions are preserved. Missing foundation requests can be constructed from the legacy foundation fields. The seven new defaults are not silently appended to an old user list.
4. Before writing migrated configuration, the installer saves the original bytes alongside the active file as `science-release.legacy-<hash>.json`. It computes the filename itself and preserves the original source file.
5. Legacy Windows JSON without a package list needs its **matching original `science-release.ps1` in the same legacy folder**. The literal `Get-SciencePackageSpecs` array is parsed without executing the source. Unsupported dynamic code or missing source stops migration with recovery instructions.
6. An existing Science environment without a trustworthy original configuration is preserved. It is not treated as a clean install. Installed package lists include dependencies and cannot reliably reconstruct user intent; the documented old 29-package list is not a fallback.
7. A genuinely clean installation, with no previous Science environment or migratable configuration, directly receives the approved 42-request defaults. No old PowerShell file is required.

An internal `science-config-origins.json` records roots whose configuration origin has been established. It is not a second package list or package ownership database. A default created for another root cannot authorize migration of an unknown old environment.
