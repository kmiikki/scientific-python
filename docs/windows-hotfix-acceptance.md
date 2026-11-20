# Historical Windows hotfix acceptance

This guide records an earlier local validation build. For current options and acceptance status, see the [Windows installation guide](windows-installation.md) and [test results](testing.md).

The hotfix targeted OpenCV 5.1.0 with Qt6 and accepted the compatible HDF5 1.14.6 runtime. It left the user's package configuration free of an HDF5 2.2.0 pin. The user had to approve any installation.

## Hotfix installation review

1. Close Python and Spyder processes using Science. Deactivate `science` if it is active.
2. Open the Windows menu from the corrected hotfix directory. That directory already contains the fixes from the earlier patches.
3. Select option **1**. Review the dependency names proposed for removal and enter `y` only to approve that list. Review the full transaction, including the HDF5 downgrade, at the separate prompt. Both prompts default to No.
4. If any package name, version or build differs from the original hotfix plan, review the new plan before approval. Compare the exact package identities even if the counts match.
5. Run the data test below after the approved installation succeeds.

After extracting the historical ZIP, set `$bundle` to its extracted directory.

```powershell
$bundle = 'C:\local\scientific-python-windows-hotfix'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$bundle\windows\00-menu.ps1" -Mode Home
```

## Post-installation data test

Open a new PowerShell session using the process-scoped execution policy for the historical test scripts.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass
```

Run these commands in that session. Set `$bundle` and `$samples` to the extracted directory and the test sample directory.

```powershell
$bundle = 'C:\local\scientific-python-windows-hotfix'
$installer = Join-Path $bundle 'windows'
$samples = Join-Path $bundle 'acceptance-samples'
$report = Join-Path $bundle 'post-install-acceptance.json'
& "$installer\08-data-acceptance.ps1" -Output $report -SampleHdf5 @("$samples\hdf5-2.2.0-earliest.h5", "$samples\hdf5-2.2.0-latest.h5")
$LASTEXITCODE
```

The script defaults to OpenCV 5.1.0 and HDF5 1.14.6. Leave `-ExpectedOpenCV` and `-ExpectedHDF5` at their defaults for the hotfix acceptance test. The expected report has `"success": true`, `PASS` for every check and exit code `0`.

The script checks Python 3.14, Spyder 6.1.8, OpenCV 5.1.0 with Qt6, FFmpeg 9 GPL, the HDF5 runtime versions used by h5py and netCDF4, and the libnetcdf runtime version. It exercises the following operations using new temporary files.

- **HDF5.** Write a multidimensional NumPy array with gzip, shuffle, Fletcher32 and metadata attributes, then verify exact readback.
- **netCDF4.** Write compressed multidimensional data, verify the dimensions and values, and test an xarray round trip using the netCDF4 backend.
- **PyArrow.** Write a table to Parquet and verify exact readback.
- **OpenCV.** Encode and decode a PNG, then write and read six lossless FFV1 video frames through the FFmpeg backend.
- **Build capabilities.** Check OpenCV build information for Qt6 HighGUI and FFmpeg Video I/O support. The automated test checks these capabilities without opening a GUI window or camera. Check Spyder and its GUI separately.

The test removes its temporary round-trip files when it finishes. It opens the supplied HDF5 2.2.0 samples read-only and compares their SHA-256 digests before and after the read. It preserves the input samples and existing scientific data.

The samples exercise an ordinary `float64` array, gzip, shuffle, Fletcher32 and attributes with the `earliest` and `latest` file format settings. A passing run covers those sample features. A read error is reported as `FAIL`. Provide other HDF5 2.x samples with `-SampleHdf5` to check the files you need.

Finally, open Spyder using the usual Scientific Python shortcut and verify the same imports and version numbers in its kernel. These CPU, data and media checks leave GPU and CUDA acceptance to a separate test.

During development, the round-trip test ran successfully on the older OpenCV 5.0.0 and HDF5 2.2.0 runtime with adjusted version expectations. That run verified the test code. The updated runtime required its own acceptance run.

## Historical patch bundles

`scientific-python-windows-all-hotfixes.patch` contained all Windows hotfixes against the original development source. `scientific-python-windows-callback-hotfix.patch` contained the changes from the preceding local hotfix to that validation build. Each patch targeted a different starting revision. Apply only the patch for that revision and verify it first with `git apply --check`.

GitHub, tags and the published v0.1.0 bundle remained unchanged during the hotfix work.
