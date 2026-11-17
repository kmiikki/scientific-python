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

PyTorch, torchvision, LightGBM and Pingouin are optional. Bare `"pytorch"` leaves variant selection to the solver. `torchvision` can bring PyTorch as a dependency. GPU availability and compatibility are not guaranteed by this release.

Keep valid JSON: double-quoted strings, commas between items and no trailing comma or comments. Duplicate package names and conflicting repeated requests are rejected. The installer accepts named Conda MatchSpecs; Micromamba performs final dependency and MatchSpec semantic validation.

The current workflow requires six compatible foundation requests: `python`, `python_abi`, `spyder`, `apache-arrow-proc`, `opencv`, `ffmpeg`. Preserve Python 3.14 GIL, Spyder 6.1.8, CPU Arrow, OpenCV 5.x Qt6 and FFmpeg 9.x GPL. Windows's FFmpeg floor is 9.0.1; Ubuntu's is 9.0.2. Existing higher media versions cannot be downgraded. Incompatible edits stop before package commit and leave the configuration available for correction.

## What removing a request means

Install/update does not automatically remove an installed package because its name disappeared from JSON. It may still be a dependency, or an independently installed user package. Automatic synchronization, ownership tracking and dependency retirement are not implemented in this release. The Windows path refuses removal of any installed package name without a replacement.

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
