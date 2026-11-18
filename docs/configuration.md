# Package configuration and migration

To change the package selection, edit only the active JSON's **`ScientificPackages` list**, save it and select **Install/update**. You do not need a command line, checksum calculator, manifest editor or dependency list.

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

Open the installer and choose **O — Optional packages**. The menu shows the configured PyTorch backend and whether an NVIDIA device is detectable with the installed driver. Choose **1 — PyTorch CPU** or **2 — PyTorch NVIDIA CUDA**. The installer saves the selected build constraint and continues to **Install/update**. Micromamba checks available builds against Python 3.14, the other requests and, for CUDA, the driver it detects. Review the proposed package changes and approve the transaction to install. A declined transaction leaves the selection saved for the next run.

Choose **R — Remove the PyTorch request** and confirm to clear the request from the configuration. The operation returns to the menu and leaves installed packages in place. A changed selection saves the previous configuration as `science-release.optional-<SHA-256>.json` in the configuration directory. Selecting the same backend again leaves the configuration bytes and backup history intact.

Advanced users can still edit JSON. For example, `"pytorch[version='>=2.13,<3',build='cpu*']"` selects a CPU build within a version range. Plain `"pytorch"` lets Micromamba select the variant. The menu retains version and channel constraints and refuses to overwrite a specific build pin that conflicts with the new backend.

The runtime report records the backend and checks CPU matrix multiplication and autograd. With a working CUDA backend it also verifies device capability, GPU matrix multiplication and CPU–GPU transfers. Native PyTorch installation and GPU execution remain acceptance tests. See [known limitations](known-limitations.md#configuration-and-updates) for Micromamba’s CUDA solver compatibility.

Torchvision, LightGBM and Pingouin are also optional. Torchvision can bring PyTorch as a dependency.

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
2. The installer searches for matching legacy configuration in the installer folder and selected root's support location. Ubuntu uses `<root>/share/scientific-python/science-release.json`; Windows uses `<root>/science-release.json`.
3. Existing user additions, removals, channels, versions and build restrictions are preserved. Missing foundation requests can be constructed from the legacy foundation fields. The seven new defaults are not silently appended to an old user list.
4. Before writing migrated configuration, the installer saves the original bytes alongside the active file as `science-release.legacy-<hash>.json`. It computes the filename itself and preserves the original source file.
5. Legacy Windows JSON without a package list needs its **matching original `science-release.ps1` in the same legacy folder**. The literal `Get-SciencePackageSpecs` array is parsed without executing the source. Unsupported dynamic code or missing source stops migration with recovery instructions.
6. An existing Science environment without a trustworthy original configuration is preserved. It is not treated as a clean install. Installed package lists include dependencies and cannot reliably reconstruct user intent; the documented old 29-package list is not a fallback.
7. A genuinely clean installation, with no previous Science environment or migratable configuration, directly receives the approved 42-request defaults. No old PowerShell file is required.

An internal `science-config-origins.json` records roots whose configuration origin has been established. It is not a second package list or package ownership database. A default created for another root cannot authorize migration of an unknown old environment.
