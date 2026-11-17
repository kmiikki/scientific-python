# Changelog

## 0.1.0 Development Release — preparation, 2026-11-17

### Added

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
