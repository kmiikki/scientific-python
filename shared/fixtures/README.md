# Shared contract fixtures

`configuration-cases.json` applies small changes to the one shared default template; it is not another package profile or runtime default list. Both native validators use these same positive and negative cases.

`linux-legacy.json`, `windows-legacy.json` and `windows-legacy-release.ps1` are unmodified copies of the original reference configuration/package-definition inputs. They exist only to test migration. Runtime does not source or execute the legacy PowerShell file.

`approved-linux-records.json` is a reduced real-record snapshot of the 42 requested packages from the v1.1 `ubuntu2404-x86_64-seven.json` dry-run response in the prior analysis. It tests the inherited no-removal policy without installing packages or repeating a solver matrix. It is not a package specification, lock file or ownership manifest for production.
