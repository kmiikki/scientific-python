# Implementation and safety model

## Source layout

| Directory | Purpose |
|---|---|
| `shared/` | Schema, default configuration, strict JSON helper and cross-platform fixtures |
| `windows/` | Windows PowerShell menu, preparation, bootstrap, transaction, launch and removal helpers |
| `linux/` | Bash menu and Python standard-library installer, transaction, safety and launcher helpers |
| `tests/` | Configuration regressions and isolated native Micromamba contract tests |
| `tools/` | Maintainer integrity regeneration and the existing bounded Bleach investigation helper |
| `docs/` | User guides, technical notes, tests and release checklist |

Original Windows V12-r2 and Linux V4-r5.2 reference installers, historical analysis, implementation reports and solver evidence are retained locally outside the public Git allowlist. Their contents are unchanged. The previous technical README is preserved locally as `reports/readme-v1.2.md`; this document and the configuration guide describe the current implementation.

## Configuration contract

Active schema-v1 JSON has exactly `SchemaVersion`, `Channels` and `ScientificPackages`. It is stored in the persistent per-user configuration directory. The shared default contains 42 requests: 29 earlier scientific requests, six foundations and seven additions (SHAP, PyWavelets, Optuna, Plotly, Hypothesis, Polars, XGBoost). Windows adapts only the FFmpeg minimum from 9.0.2 to 9.0.1.

Python validation and Windows's .NET/PowerShell validation enforce the same fixture contract. `StrictJson.cs` provides duplicate-key and strict syntax checks before PowerShell object conversion; no installed scientific Python is needed on Windows. Named MatchSpecs are screened locally and fully interpreted by Micromamba.

Migration preserves user list changes and restrictions, saves original bytes and refuses uncertain origins. `science-config-origins.json` associates established configuration provenance with selected roots. It does not record package ownership or infer direct requests from transitive packages. See [migration rules](configuration.md#migration-rules).

## Integrity boundary

Each platform's `SHA256SUMS.txt` covers its scripts, resources, immutable `science-installer-release.json` and shared schema/default/helper. Runtime verification supports sibling `shared/` in a source extraction and a child `shared/` in installed support files. Entry points verify before loading mutable helpers. Editable active JSON, legacy backups and origin receipts are excluded from fixed manifests.

`tools/refresh_integrity.py` is a maintainer operation after reviewed source edits. Bootstrap metadata pins Micromamba 2.10.0. Source-level consistency is checked separately by `SOURCE-SHA256SUMS.txt`. `.gitattributes` disables automatic newline conversion so Windows and Linux Git checkouts retain the verified bytes. A trusted acquisition channel is still necessary; these files are not digital signatures.

## Windows approved-plan execution

The existing menu/bootstrap/layout/launcher/removal structure is retained. `science-update.ps1` performs the initial solve using configured channels and release policy; `science-transaction.ps1` seals and executes the approved package identities.

1. Read installed records, reject duplicates, validate the root/prefix and exclude active Science processes. Acquire an exclusive installer update lock.
2. Resolve before approval. Validate required requests, Python 3.14 ordinary GIL, Spyder 6.1.8, CPU Arrow, OpenCV 5.x Qt6 and FFmpeg 9.x GPL, including media no-downgrade floors. Refuse removal of installed names without replacements.
3. Freeze the before/after universe, approved LINK/UNLINK records, target prefix, installed-metadata digest, active-configuration hash and executable hash. Show actions and bind approval to the serialized lock SHA256.
4. Copy a matching archive from the package cache, or download its approved HTTPS URL. Verify SHA256. Stage approved LINK archives in a private transaction directory; the normal package cache is a read source.
5. Generate an `@EXPLICIT` file with local file URLs and SHA256 fragments. Generate a local channel containing exactly the final approved records and a full exact-spec environment input. Seal these inputs.
6. Use Micromamba `create --download-only --offline --file …` to extract the approved archives into a private cache. Compare its reported identities.
7. For a new environment, use explicit `create`. For an update, use `env update --prune --offline --file …` against the frozen local universe. This uses Micromamba's solver, with no alternative versions or builds available. The complete retained universe prevents pruning independent user packages.
8. Run a native dry run and compare both LINK and UNLINK identities (name, version, build, subdir, SHA256) with the approved plan. Recheck lock, inputs, archives, configuration, binary and installed metadata before commit. Apply the narrowly approved legacy GTK hook guard immediately before native execution.
9. Commit the same frozen command offline, compare the reported event and installed final identities, restore original source/dependency metadata and validate the GTK cache. Never claim automatic rollback.

Micromamba 2.10.0's actual CLI was inspected and its operations exercised with inert noarch archives. A plain `@EXPLICIT` install does not produce the required UNLINK plan for a version/build replacement, so it is not used as a general update shortcut.

For the inherited missing GTK payload checks, a separate native explicit same-identity relink is solved/reviewed before the main update. The test verifies restoration of a missing file. This avoids relying on `--force-reinstall` to resolve remote installed-channel records from a new local channel. Repair changes to identities are rejected.

The phase-1/2 Windows execution gates are replaced by this checked path. Calling the lower-level executor without a matching approval digest is rejected. Unverifiable historical records stop safely. Unknown native behavior or a different transaction does not unlock a fallback.

## Ubuntu path

The existing V4-r5.2 implementation remains: guarded roots/ownership, process checks, approved frozen transactions, bootstrap receipts, package/media verification, managed launchers and narrowly scoped removal. Release preparation fixes the preflight display's positional assumption about media requests and updates development-version metadata. The Spyder follow-up also resolves file-loaded project dependencies explicitly relative to their bundle, without modifying global import paths; see the [startup fix](spyder-startup-fix.md).

Read-only review checked menu dispatch, JSON loading, immutable manifests, bootstrap verification, transaction identity checks, launcher creation and removal boundaries. Isolated tests cover the changed preview and existing configuration/safety boundaries. No production environment was altered to establish readiness.

## Release-default configuration additions

After initialization/migration, interactive installers offer missing default requests by package identity. Accepted candidates use guarded atomic replacement; declined or non-interactive runs preserve the active JSON. Both runtime checkers load `shared/science_package_report.py` by file location for pure coverage reporting and the seven import aliases. It is included in immutable manifest completeness checks and installed support copies. This does not change the native transaction or introduce package ownership/removal. See [root cause and safety contract](release-package-upgrade.md).

## Deferred work

No new Synchronize command, ownership engine, pending-retirement policy, automatic rollback or optional/GPU matrix is implemented. Configuration provenance and transaction locks do not imply those features.

## Upstream references

- [Micromamba user guide](https://mamba.readthedocs.io/en/stable/user_guide/micromamba.html).
- [Micromamba releases](https://github.com/mamba-org/micromamba-releases/releases), with the pinned binary identities in platform release metadata.
- [PowerShell 7.4.6 test runtime](https://github.com/PowerShell/PowerShell/releases/tag/v7.4.6); this runtime is not bundled.
