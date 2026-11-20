# Third-party notices and license scope

The [MIT License](LICENSE) covers this project's installer source and documentation. It does not relicense software downloaded or installed by the scripts.

## Source review

The public source allowlist was reviewed for copyright/license headers, vendored implementations, copied code markers and bundled binaries. No third-party implementation source requiring a separate retained source license was identified in the shipped scripts, strict JSON helper or generated test fixtures. The small OpenCL activation replacements and GTK guard are project-specific scripts; they do not embed upstream DLLs or Python package implementations.

Original reference archives and historical evidence are retained locally and excluded from the public distribution. Portable test runtimes and package archives are not bundled. This records the source review performed for preparation; future contributions must retain their required provenance and notices.

## Downloaded and installed software

- **Micromamba / libmamba:** upstream [BSD 3-Clause license](https://github.com/mamba-org/mamba/blob/main/LICENSE), with upstream copyright notices. The installer downloads a pinned executable and verifies its SHA256.
- **PowerShell:** the optional portable test runtime is obtained from [Microsoft's PowerShell release](https://github.com/PowerShell/PowerShell/releases/tag/v7.4.6) and is not redistributed here. Windows normally uses the system's Windows PowerShell.
- **Python, scientific libraries and their native dependencies:** each retains its own license and copyright notices as distributed in the Conda packages. Consult the installed package metadata and upstream license files for redistribution requirements.
- **FFmpeg:** the selected build is a **GPL variant**. The installer project's MIT license does not change FFmpeg's license or the obligations of redistributing that build and its dependencies.

The synthetic contract-test archives are generated from this project's tiny fixture builder. They contain only generated metadata and text, and no third-party runtime code.

The root MIT text follows the [Open Source Initiative MIT template](https://opensource.org/license/mit).
