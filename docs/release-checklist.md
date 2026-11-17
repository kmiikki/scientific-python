# v0.1.0 Development Release checklist

## Preparation

- [x] Shared default remains 42 direct requests; no unsolicited package additions or Bleach pins.
- [x] Safe migration and user-editable JSON remain separate from immutable manifests.
- [x] Windows approval is bound to an exact plan and checked offline execution path.
- [x] Existing Ubuntu path reviewed without changing a live environment.
- [x] Required automated regressions and focused transaction tests passed.
- [x] Science activation/Spyder sibling-import fix: isolated regressions and real Micromamba activation/deactivation in a temporary root and a real headless Science kernel passed; existing installations were preserved.
- [x] English README, platform guides, configuration and technical documentation prepared.
- [x] MIT text and third-party scope reviewed.
- [x] Final public-file, relative-link, secret/path and extracted-distribution audit recorded.
- [x] First local Git commit prepared and recorded by delivery; no remote publication.

## User review before publication

- [ ] Review [README](../README.md), all `docs/` Markdown, [changelog](../CHANGELOG.md) and [third-party notices](../THIRD_PARTY_NOTICES.md).
- [ ] Review the final change list and local Git commit.
- [ ] Decide whether pending native acceptance permits a clearly labelled development release.
- [ ] Give separate explicit approval for creating a GitHub repository/pushing/publishing.

## Supervised native acceptance — do not pre-mark passed

For Ubuntu 24.04, Ubuntu 26.04 and Windows 11 separately:

- [ ] Identify and verify the exact Science path and removal target; record other environments to preserve.
- [ ] Remove only Science and install with the new source.
- [ ] Start Spyder and the first IPython kernel.
- [ ] Check NumPy, OpenCV/FFmpeg and imports of SHAP, PyWavelets, Optuna, Plotly, Hypothesis, Polars and XGBoost.
- [ ] Check application/desktop/command launchers and persistence after signing in again.
- [ ] Confirm other environments are unchanged.

Windows additionally requires native PowerShell 5.1, bootstrap, UAC/preparation and DLL/hook verification. Do not perform these destructive acceptance steps automatically on the development host.

## Publication boundary

This preparation authorizes only a local repository and local commit. No GitHub repository, push, remote tag or release is authorized. Stop for user documentation review after delivering the local result.
