"""Scientific Python V12 checks; no camera or GUI is opened by default.

Use runpy.run_path(..., run_name='__main__') in a Spyder kernel to check that
kernel's actual executable search path. Output contains no absolute paths.
"""
import argparse
import hashlib
import importlib
import importlib.metadata as md
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from packaging.version import Version

IMPORTS = ('numpy scipy pandas matplotlib seaborn sympy statsmodels sklearn skimage cv2 PIL '
           'imageio xarray h5py netCDF4 pyarrow openpyxl xlsxwriter jupyterlab ipykernel IPython '
           'spyder spyder_kernels numba tqdm pint uncertainties serial pip shapely exifread imageio_ffmpeg').split()
_bundle = Path(__file__).resolve().parent
_shared=_bundle/'shared' if (_bundle/'shared').is_dir() else _bundle.parent/'shared'
_spec=importlib.util.spec_from_file_location('science_package_report',_shared/'science_package_report.py')
_package_report=importlib.util.module_from_spec(_spec);_spec.loader.exec_module(_package_report)
_DEFAULTS=json.loads((_shared/'science-release.default.json').read_text(encoding='utf-8-sig'))
RELEASE = json.loads((_bundle/'science-installer-release.json').read_text(encoding='utf-8-sig'))
_user_path = Path(os.environ['LOCALAPPDATA'])/'ScientificPython/science-release.json'
_user = json.loads(_user_path.read_text(encoding='utf-8-sig'))
RELEASE.update(_user)
_names = {_package_report.package_name(s) for s in _user['ScientificPackages']}
_aliases = {'sklearn':'scikit-learn','skimage':'scikit-image','cv2':'opencv','PIL':'pillow','netCDF4':'netcdf4','IPython':'ipython','serial':'pyserial','imageio_ffmpeg':'imageio-ffmpeg','spyder_kernels':'spyder'}
IMPORTS = [m for m in IMPORTS if _aliases.get(m,m) in _names]
IMPORTS += [m for p,m in _package_report.RELEASE_IMPORTS.items() if p in _names]



def run(args, timeout=60):
    p = subprocess.run([str(x) for x in args], capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout)
    if p.returncode:
        raise RuntimeError('command_exit_' + str(p.returncode))
    return p.stdout + p.stderr

def package_records(prefix):
    records=[]
    for file in (Path(prefix)/'conda-meta').glob('*.json'):
        try:records.append(json.loads(file.read_text(encoding='utf-8')))
        except (ValueError,OSError):pass
    return records


def package_selection(prefix,imports=(),records=None):
    return _package_report.coverage(_user,_DEFAULTS,package_records(prefix) if records is None else records,imports)


def checks(prefix=None, gui=False):
    prefix = Path(prefix or sys.prefix).resolve()
    result = {'schema': 12, 'checks': {}, 'versions': {}, 'tools': {}, 'optional': {}}
    def check(name, fn):
        try:
            value = fn()
            if value is False: raise RuntimeError('unexpected_result')
            result['checks'][name] = {'status': 'PASS'}
            return value
        except Exception as exc:
            # Do not serialize messages, tracebacks, device names or environment values.
            result['checks'][name] = {'status': 'FAIL', 'error_type': type(exc).__name__}
            return None
    check('interpreter_prefix', lambda: Path(sys.prefix).resolve() == prefix)
    check('python_release_gil', lambda: sys.version_info[:2] == tuple(map(int,RELEASE['Python'].split('.'))) and not bool(__import__('sysconfig').get_config_var('Py_GIL_DISABLED')))
    imports=[]
    for name in IMPORTS:
        check('import_' + name, lambda name=name: importlib.import_module(name))
        imports.append({'package':_aliases.get(name,name).lower(),'module':name,'status':result['checks']['import_'+name]['status']})
    for name in ['spyder','spyder-kernels','ipykernel','numpy','numba','opencv','shapely','ExifRead','imageio-ffmpeg']:
        try: result['versions'][name] = md.version(name if name != 'opencv' else 'opencv-python')
        except md.PackageNotFoundError: pass
    check('spyder_version', lambda: md.version('spyder') == RELEASE['Spyder'])
    records=package_records(prefix)
    torch_requests = _package_report.PYTORCH_REQUESTS & _names
    if torch_requests:
        backend = _package_report.pytorch_backend(_user['ScientificPackages'])
        torch_report = check('pytorch_backend', lambda: _package_report.pytorch_probe(torch_requests, backend))
        if torch_report is not None:
            result['optional']['pytorch'] = torch_report
        imports.extend({'package': name, 'module': 'torch', 'status': result['checks']['pytorch_backend']['status']}
                       for name in sorted(torch_requests))
    result['package_selection']=package_selection(prefix,imports,records)
    check('effective_package_names',lambda: not result['package_selection']['missing_effective'])
    def record_ok(name, version=None, build=None):
        return any(r.get('name') == name and (version is None or re.fullmatch(version,r.get('version',''))) and
                   (build is None or re.search(build,r.get('build',''))) for r in records)
    check('arrow_cpu_variant', lambda: record_ok('apache-arrow-proc', build=r'^cpu$'))
    import cv2
    check('opencv_qt6_variant', lambda: record_ok('opencv', None, r'^qt6') and Version(RELEASE['OpenCV']) <= Version(cv2.__version__) < Version(RELEASE['OpenCVMaxExclusive']))
    check('ffmpeg_gpl_variant', lambda: record_ok('ffmpeg',None,r'^gpl') and any(r.get('name')=='ffmpeg' and Version(RELEASE['FFmpeg'])<=Version(r['version'])<Version(RELEASE['FFmpegMaxExclusive']) for r in records))
    import cv2
    info=cv2.getBuildInformation()
    check('opencv_highgui_qt6', lambda: bool(re.search(r'GUI:\s+QT6',info)))
    check('opencv_ffmpeg_videoio', lambda: bool(re.search(r'FFMPEG:\s+YES',info)))
    check('opencv_directshow_backend', lambda: cv2.CAP_DSHOW in cv2.videoio_registry.getBackends())
    tools={n:prefix/'Library'/'bin'/(n+'.exe') for n in ['ffmpeg','ffprobe']}
    for name,exe in tools.items():
        check(name+'_present',lambda exe=exe: exe.is_file())
        check(name+'_search_identity',lambda name=name,exe=exe: bool(shutil.which(name)) and Path(shutil.which(name)).resolve() == exe.resolve())
        check(name+'_version',lambda exe=exe: Version(RELEASE['FFmpeg']) <= Version(re.search(r'version\s+(\d+\.\d+(?:\.\d+)?)',run([exe,'-version'])).group(1)) < Version(RELEASE['FFmpegMaxExclusive']))
        if exe.is_file():
            with exe.open('rb') as f:
                result['tools'][name]={'sha256':hashlib.file_digest(f,'sha256').hexdigest(),'expected_prefix_search':result['checks'][name+'_search_identity']['status']}
    ff=tools['ffmpeg']; probe=tools['ffprobe']
    def capabilities():
        for flag,features in [('-devices',['dshow','lavfi']),('-encoders',['ffv1','libx264']),
                              ('-decoders',['ffv1','rawvideo','mjpeg']),('-muxers',['matroska','tee','fifo','nut']),
                              ('-demuxers',['matroska'])]:
            output=run([ff,'-hide_banner',flag])
            if not all(re.search(r'\b'+x+r'\b',output) for x in features): return False
        return '--enable-gpl' in run([ff,'-version'])
    check('ffmpeg_capabilities',capabilities)
    def clip():
        with tempfile.TemporaryDirectory(prefix='science-media-') as tmp:
            file=Path(tmp)/'synthetic.mkv'
            run([ff,'-v','error','-f','lavfi','-i','testsrc2=size=64x48:rate=10','-frames:v','3','-c:v','ffv1',file])
            metadata=json.loads(run([probe,'-v','error','-show_streams','-show_packets','-of','json',file]))
            assert metadata['streams'][0]['codec_name']=='ffv1'
            times=[float(p['pts_time']) for p in metadata['packets'] if p.get('codec_type')=='video']
            assert len(times)==3 and all(b>a for a,b in zip(times,times[1:]))
            run([ff,'-v','error','-i',file,'-f','null','-'])
            cap=cv2.VideoCapture(str(file),cv2.CAP_FFMPEG)
            try:
                assert cap.isOpened()
                assert sum(bool(cap.read()[0]) for _ in range(3))==3
            finally: cap.release()
        return True
    check('ffv1_mkv_roundtrip_pts_opencv',clip)
    def geometry():
        from shapely.geometry import Polygon
        return Polygon([(0,0),(1,0),(1,1)]).area == 0.5
    if 'shapely' in _names: check('shapely_geos',geometry)
    if shutil.which('mkvmerge'):
        result['optional']['mkvtoolnix']='PASS' if check('mkvmerge',lambda: 'mkvmerge' in run(['mkvmerge','--version'])) else 'FAIL'
    else: result['optional']['mkvtoolnix']='NOT_INSTALLED: required for retiming; see EXTERNAL_TOOLS.md'
    if gui:
        def window():
            import numpy as np
            cv2.namedWindow('Scientific Python V12 check')
            try:
                cv2.imshow('Scientific Python V12 check',np.zeros((120,160,3),np.uint8))
                cv2.waitKey(500)
            finally: cv2.destroyAllWindows()
            return True
        check('highgui_window',window)
    result['success']=all(v['status']=='PASS' for v in result['checks'].values())
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--prefix')
    parser.add_argument('--output')
    parser.add_argument('--gui',action='store_true')
    args=parser.parse_args()
    try: result=checks(args.prefix,args.gui)
    except Exception as exc:
        result={'success':False,'error_type':type(exc).__name__,'package_selection':package_selection(Path(args.prefix or sys.prefix))}
    payload=json.dumps(result,ensure_ascii=True,indent=2)
    if args.output: Path(args.output).write_text(payload+'\n',encoding='utf-8')
    print(payload)
    sys.exit(0 if result['success'] else 1)
