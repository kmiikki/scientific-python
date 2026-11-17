# Single source of release constraints. Ordinary CPython (GIL), Windows x64.
$script:ScienceRelease = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'science-release.json') -Raw | ConvertFrom-Json
function Get-SciencePackageSpecs {
    @(
        "python=$($script:ScienceRelease.Python)"
        "python_abi=$($script:ScienceRelease.Python)=*_cp$($script:ScienceRelease.Python.Replace('.',''))"
        "spyder=$($script:ScienceRelease.Spyder)"
        'apache-arrow-proc=*=cpu'
        "opencv[version='>=$($script:ScienceRelease.OpenCV),<$($script:ScienceRelease.OpenCVMaxExclusive)',build='qt6*']"
        "ffmpeg[version='>=$($script:ScienceRelease.FFmpeg),<$($script:ScienceRelease.FFmpegMaxExclusive)',build='gpl*']"
        'numpy'; 'scipy'; 'pandas'; 'matplotlib'; 'seaborn'; 'sympy'
        'statsmodels'; 'scikit-learn'; 'scikit-image'; 'pillow'; 'imageio'
        'xarray'; 'h5py'; 'netcdf4'; 'pyarrow'; 'openpyxl'; 'xlsxwriter'
        'jupyterlab'; 'ipykernel'; 'ipython'; 'numba'; 'tqdm'; 'pint'
        'uncertainties'; 'pyserial'; 'pip'; 'shapely'; 'exifread'; 'imageio-ffmpeg'
    )
}
function Get-ScienceFileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    $stream=[IO.File]::OpenRead($Path)
    try { -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
    finally { $stream.Dispose(); $sha.Dispose() }
}
