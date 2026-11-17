# v0.1.0 release-preparation result

Prepared on 2026-11-17. This is a local development-release preparation; no GitHub repository, push, remote tag or release was created.

## Source changes

- Enabled Windows package execution through displayed, SHA256-bound approval and verified offline native inputs. Rechecked approved LINK/UNLINK and installed identities; preserved the original bootstrap, layout, launcher, hook and removal structure.
- Bound the lock to configuration bytes, executable bytes, prefix and installed metadata; changes before commit stop safely. Necessary GTK missing-file relinks have separate review/approval.
- Preserved the accepted configuration/migration/default rules. Windows menu now checks migration before preparation changes Windows settings.
- Fixed broken Windows error-preference assignments and an embedded BOM that prevented the launcher helper's first function from loading.
- Fixed Ubuntu preflight's positional interpretation of media requests. The rest of the existing Ubuntu transaction/removal path is retained.
- Added English user/technical documentation, MIT license, third-party scope, public-file ignores and a repeatable release audit.

Windows execution is now implemented and available behind the checked approval path. Isolated native Micromamba 2.10.0 tests validate its CLI contract. This does not constitute native Windows 11 / PowerShell 5.1 acceptance.

## Verification

| Check | Result |
|---|---|
| Python unittest | 17/17 passed |
| PowerShell configuration/entry regressions | 51/51 passed on Linux PowerShell 7.4.6 |
| Targeted transaction contract | 23/23 passed on Linux PowerShell 7.4.6 + Micromamba 2.10.0 |
| Bash syntax / safe Linux entry smoke | 11/11 passed: eight Bash parses and three entry checks |
| Public-source manifests, links, file/secret/path audit | Passed |
| Extracted public distribution and installed-style shared-resource layout | Verified during final preparation |
| Original references, analysis and historical evidence | Preserved unchanged locally |

The native contract fixtures contain only small generated text files. Test roots, runtimes and caches were kept in RAM-backed `/tmp`; temporary environment roots were cleaned. The existing production Science and other environments were not changed. No broad solver matrix or Bleach rerun was performed.

## Pending acceptance and limits

Native Windows 11 / PowerShell 5.1, Ubuntu 24.04/26.04 remove/install, full scientific runtime, Spyder/first kernel, desktop login persistence and optional/GPU combinations remain unaccepted. No automatic rollback, Synchronize, ownership engine or pending-retirement feature is claimed. Native acceptance and user documentation review remain the gates before treating the development release as publicly ready.

No unresolved approved-plan mismatch remains in the isolated supported executor paths. Unknown or unverifiable native events still stop. A partial native commit can require manual diagnosis; it is not reported as a rollback or success.

## Local Git

The project is initialized locally with an explicit public file allowlist and the commit message `Initial development release preparation (v0.1.0)`. The concrete commit ID and clean-state verification are recorded in the local delivery result and reported to the user; a document inside that first commit cannot contain its own resulting hash. No remote is configured by this work.

Historical reports and original archives are preserved locally, outside Git. The source-only archive is generated from the tracked file set and checked against the platform manifests; no Micromamba binary, environment, package cache or user configuration is included.

## Markdown review inventory

All Markdown intended for publication:

- [README](../README.md)
- [Changelog](../CHANGELOG.md)
- [Third-party notices](../THIRD_PARTY_NOTICES.md)
- [Ubuntu installation](ubuntu-installation.md)
- [Windows installation](windows-installation.md)
- [Configuration and migration](configuration.md)
- [Known limitations](known-limitations.md)
- [Technical architecture](architecture.md)
- [Testing](testing.md)
- [Release checklist](release-checklist.md)
- [This preparation report](release-preparation.md)
- [Shared fixture notes](../shared/fixtures/README.md)

The official [MIT license](../LICENSE) contains copyright © 2026 Kim Miikki. No bundled third-party implementation requiring a separate source license was identified in the public-source review; downloaded packages keep their own licenses, including the FFmpeg GPL variant.

Next: review these documents, perform supervised native acceptance as appropriate, and give separate approval before any GitHub publication. See the [short release checklist](release-checklist.md).
