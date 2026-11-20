# 🔬 Scientific Python Environment

**A comprehensive scientific Python environment — without the installation headaches.**

*Stop fighting dependencies. Start doing science.*

🐧 Ubuntu 24.04 / 26.04 · 🪟 Windows 11 · 🐍 Python 3.14 · 📄 MIT License

Set up a scientific Python workspace with **Spyder, JupyterLab, numerical tools, machine learning, image processing and video support**. A guided menu checks your setup, resolves dependencies and asks you to approve the package changes.

**v0.9.2 development.** Fresh installations offer a PyTorch choice. The installer reports progress from package approval through verification, and the removal menu separates Science, the Micromamba executable and the whole Micromamba directory. The [USB Camera Test](docs/camera-testing.md) is optional. See [known limitations](docs/known-limitations.md) before installing.

[Ubuntu guide](docs/ubuntu-installation.md) · [Windows guide](docs/windows-installation.md) · [Customize packages](docs/configuration.md) · [Development and releases](docs/release-checklist.md)

## 🎯 Why This Project?

Getting Python libraries to work together can take time away from research and learning. This project brings a broad selection into one environment, with a consistent installation workflow on Windows and Ubuntu.

You do not need to learn Conda commands to use the installer. To customize the package selection, edit **one JSON list** and run **Install/update** again. The installer validates the configuration, resolves dependencies, downloads packages and verifies their checksums automatically.

## ✨ Key Features

- **A ready-made scientific workspace:** 42 direct package requests, plus their dependencies.
- **Familiar development tools:** Spyder 6.1.8, IPython and JupyterLab.
- **One editable package list:** your choices survive installer source updates.
- **Reviewed package changes:** approved versions, builds and archive hashes are checked again before execution.
- **Careful migration:** previous choices are backed up and preserved; uncertain legacy installations stop for clarification.
- **User-scoped environments:** installation and removal target the selected Science environment, with checks protecting other environments.

## 💻 Supported Platforms

| Platform | Target | Acceptance status |
|---|---|---|
| Ubuntu 24.04 LTS | x86-64, desktop session | v0.9.2 fresh installs and Science removal with and without CUDA PyTorch passed in native Ubuntu 24.04 LTS tests. GPU computation, camera and installation progress checks passed. |
| Ubuntu 26.04 LTS | x86-64, desktop session | Earlier fresh installation passed. Current update and legacy ownership acceptance pending. |
| Windows 11 | x86-64, Windows PowerShell 5.1 | v0.9.2 PowerShell checks passed on Linux. Native integrated installer acceptance is pending. |

The environment uses ordinary **GIL-enabled Python 3.14**, **OpenCV 5.x with Qt6** and **FFmpeg 9.x GPL**. ARM systems and other operating systems are outside this release's scope.

## 🚀 Quick Start

On the project’s GitHub page, choose **Code → Download ZIP** to download `scientific-python-main.zip`. Use the **Releases** tab for tagged milestones.

Keep the **entire extracted project folder** together, including `shared/`. Do not copy a single installer script out of it. Work from a trusted source copy; the local manifests check file consistency, not publisher identity.

### Ubuntu 24.04 / 26.04

1. Open a terminal in the extracted project folder.
2. Start the menu:

   ```bash
   bash linux/00-menu.sh
   ```

3. Choose **1 — Install/update Scientific Python**, select a layout and review the proposed changes. The recommended new directory is `~/micromamba`. Choose **Existing** to reuse a previous one.
4. After installation, launch **Scientific Python - Spyder** from the application menu, or run `science-spyder` in a new terminal. A desktop shortcut is offered where supported.

Run as your normal user. Normal installation does not require `sudo`. Ubuntu's system Python 3 and Bash start the installer; it creates the scientific Python environment separately. See the [Ubuntu guide](docs/ubuntu-installation.md) for existing installations and removal.

### Windows 11

1. Extract the whole project folder to a local folder.
2. Open `windows/` and double-click **`00-START-HERE.cmd`**.
3. Choose **1 — Install/update Scientific Python**, then review the selected layout and package transaction. Use your normal account. Preparation may request elevation for a required Windows setting. Restart Windows if prompted, then choose option 1 again.
4. Launch **Scientific Python science - Spyder** from the desktop shortcut, or use `science-spyder.cmd` from a new terminal after PATH setup.

The usual environment location is `%USERPROFILE%\micromamba\envs\science`. An alternative **Safe** layout uses a dedicated per-user directory under `C:\micromamba`. See the [Windows guide](docs/windows-installation.md) for preparation and migration requirements.

## 📦 Included Packages

| Work | Examples |
|---|---|
| 🔬 Scientific computing | NumPy, SciPy, SymPy, Numba, Pint, uncertainties |
| 📊 Data analysis | pandas, Polars, Xarray, Statsmodels, PyArrow, HDF5 and NetCDF tools |
| 📈 Visualization | Matplotlib, Seaborn, Plotly |
| 🤖 Machine learning | scikit-learn, XGBoost, SHAP, Optuna |
| 📷 Images and video | OpenCV, scikit-image, Pillow, ImageIO, PyWavelets, FFmpeg |
| 🧪 Interactive development and testing | Spyder, JupyterLab, IPython, Hypothesis |
| 📁 Files and instruments | openpyxl, XlsxWriter, pyserial, ExifRead, Shapely |

The [complete default configuration](shared/science-release.default.json) contains all 42 direct requests. Windows uses an FFmpeg minimum of 9.0.1; Ubuntu uses 9.0.2. Additional dependencies are resolved automatically.

A fresh installation defaults to **No PyTorch**. Choose [PyTorch CPU or NVIDIA CUDA](docs/configuration.md#optional-pytorch) there or use **O — Configure optional packages and install/update** to change an existing selection. Torchvision, LightGBM and Pingouin can also be requested.

## ⚙️ Configuration

After selecting an installation target, the installer creates or migrates your active `science-release.json`:

| Platform | Default active configuration |
|---|---|
| Ubuntu | `~/.config/scientific-python/science-release.json` (or the configured XDG location) |
| Windows | `%LOCALAPPDATA%\ScientificPython\science-release.json` |

Open that file in a text editor and change **only `ScientificPackages`**. For example, add `"pingouin"`, or replace `"numpy"` with `"numpy>=2,<3"`. Keep valid JSON commas and quotes, then run Install/update again.

Interactive Install/update now offers absent release-default requests before solving. The default answer is **No**; approval appends only the displayed requests and preserves your constraints and channels. Non-interactive runs preserve the file. Effective-configuration success and release-default coverage are [reported separately](docs/release-package-upgrade.md).

**You never need to calculate checksums, edit manifests, resolve dependencies by hand or run package-management commands.** The six foundation requests must remain compatible with this release's Python, Spyder, Arrow and media policy. See [configuration and migration](docs/configuration.md).

## 🔄 Updating Your Environment

Use **1 — Install/update Scientific Python**. Your active JSON remains authoritative after extracting a new installer. After approval, step `[6/9] Installing packages` reports elapsed time and activity about every five seconds during longer operations, including package verification after Micromamba exits.

Removing a request from JSON stops requesting it. **This release does not automatically uninstall an already installed package when its request is removed.** It may also remain required by another package. Package synchronization and ownership tracking are future work.

## 🛠️ Troubleshooting

- **Migration stops:** restore the original configuration and, for legacy Windows JSON without a package list, its matching `science-release.ps1`. Existing installed dependencies cannot reliably reconstruct your original choices.
- **Configuration is rejected:** check JSON quotes, commas, duplicate package names and incompatible version/build restrictions.
- **Environment is in use:** close Spyder, kernels and other Science processes, then try again.
- **Checksum or approved-plan mismatch:** stop and inspect the reported evidence; the installer will not silently substitute another plan.
- **Startup or media problem:** use menu **D**, then follow the [troubleshooting guide](docs/known-limitations.md#troubleshooting-and-reporting).

## 📝 Known Limitations

Interrupted native package commits have no guaranteed automatic rollback. See the [0.9.2 Ubuntu acceptance results](docs/testing.md#v092-ubuntu-2404-lts-acceptance), [known limitations](docs/known-limitations.md) and [technical design](docs/architecture.md).

## 🤝 Contributing

Reproducible reports and small, focused improvements are welcome. Include your OS version, installer version, the failing step and redacted diagnostics. Remove private paths, credentials and project data before sharing logs. See [testing](docs/testing.md) for the maintainer checks.

## 📄 License

Installer source code is licensed under the [MIT License](LICENSE). Micromamba and the installed Python/native packages retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
