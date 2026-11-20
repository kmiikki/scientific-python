# Changelog

## v0.9.2 development

- Show a consistent platform heading on the main menu and installation screens. Show the Ubuntu Current / Target summary once before Micromamba validation.
- Offer No PyTorch, CPU and NVIDIA CUDA during fresh installation. Check GPU and driver compatibility only for CUDA requests.
- Use one elapsed-time clock for the approved package phase, including archive preparation, Micromamba execution and installer verification.
- Clarify the separate removal actions and normal cancellation messages. Scope the Ubuntu Science preservation check to sibling environment entries and shared resource boundaries.
- Record Ubuntu 24.04 LTS fresh installation, CUDA computation, Science removal, USB camera and installation progress acceptance. Native Windows 11 installer acceptance remains pending.

## v0.9.1 development

- Give the first Windows camera preview its own HighGUI initialization deadline, and preserve validated frames if preview or cleanup fails.

- Windows camera discovery tries bounded DirectShow index probes when native enumeration is empty. Worker startup has a separate timeout from device opening.

- Add the optional USB Camera Test to both installer menus and standalone launchers. Select one camera or test multiple devices independently using DirectShow on Windows and V4L2 on Ubuntu.
- Classify unsupported V4L2 nodes, validate consecutive frames in bounded workers, and optionally show live preview. Include redacted JSON results for unattended checks.
- Report Scientific Python 0.9.1 in both installers and generate versioned platform ZIPs with the camera test. Existing package configuration, layout identifiers and ownership evidence remain compatible.

## v0.9.0 development

- Integrated the cumulative Windows installer fixes for channel arguments, approval, callback scope, contaminated native JSON output and standalone launcher repair.
- Verify retained Windows packages with conda-forge before restoring missing or temporary package sources.
- Resume Windows finalization from matching approved package identities and require a matching prefix ownership marker for removal.
- Check Ubuntu Science environment ownership independently of the Micromamba root.
- Add optional PyTorch CPU/CUDA selection to both installer menus, with configuration backups and runtime backend checks.
- Verify the NVIDIA driver and GPU capability when solving CUDA packages. Document native Ubuntu 24.04 LTS acceptance for the existing-environment update, Spyder and PyTorch CUDA computation.

## 0.1.0 Development Release — preparation

### Added

- Opt-in release-default additions to existing JSON on interactive Install/update, preserving user constraints/channels and non-interactive behavior.
- Separate effective-request, release-default, installed-package and recorded-import coverage in runtime reports.

- Shared, validated JSON configuration with 42 default direct Conda requests.
- Safe migration with automatic backups and preservation of user package restrictions.
- Separate immutable installer manifests and editable user configuration.
- Windows approved-plan execution: SHA256-bound review, verified archives, offline exact inputs, LINK/UNLINK comparisons and installed-state checks.
- English platform, configuration, technical, testing and release documentation; MIT license.

### Fixed

- Ubuntu Science activation (including isolated Python hooks), managed Spyder and kernel support resolve sibling modules independently of the working directory, with no project import-path mutation.

- Windows Install/update no longer commits a fresh unconstrained online solve after approval.
- Windows entry-point error-preference assignments and an embedded BOM in the launcher helper.
- Ubuntu preflight preview handles reordered package lists and alternate valid media request syntax.
- Windows menu validates migration before Windows preparation changes settings.

### Scope

- Preserves the existing Ubuntu transaction and removal safeguards.
- No automatic synchronization, package ownership, pending-retirement or GPU combination matrix.
- Native target-system installation and Spyder/kernel acceptance remain pending. No public release has been published by this preparation step.
