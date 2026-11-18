#!/usr/bin/env python3
"""Bounded, non-hardware Ubuntu acceptance probes. Reports contain no raw logs."""
import argparse
import importlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

BUNDLE = Path(__file__).resolve().parent


def command(argv, timeout=45):
    result = subprocess.run([str(a) for a in argv], capture_output=True, text=True,
                            encoding='utf-8', errors='replace', timeout=timeout)
    if result.returncode:
        raise RuntimeError('Command failed, exit ' + str(result.returncode))
    return result.stdout + result.stderr


def require(value, reason):
    if not value:
        raise AssertionError(reason)


def metadata(prefix):
    return {r['name']: r for file in (prefix / 'conda-meta').glob('*.json')
            for r in [json.loads(file.read_text(encoding='utf-8'))]}


def identity(prefix):
    require(Path(sys.prefix).resolve() == prefix.resolve(), 'Wrong Python prefix')
    require(Path(os.environ.get('CONDA_PREFIX', '/missing')).resolve() == prefix.resolve(), 'Environment was not activated')
    for name in ['ffmpeg', 'ffprobe']:
        resolved = shutil.which(name)
        require(resolved and Path(resolved).resolve() == (prefix / 'bin' / name).resolve(), 'Wrong executable: ' + name)
    return {'python_in_science': True, 'conda_prefix_matches': True, 'ffmpeg_in_science': True, 'ffprobe_in_science': True}


def frontend_receipt(prefix):
    launch_id = os.environ.get('SCIENCE_SPYDER_LAUNCH_ID', '')
    require(bool(re.fullmatch('[0-9a-f]{32}', launch_id)), 'Kernel did not inherit a managed Spyder launch')
    receipt = prefix.parent.parent / '.science-launch' / (launch_id + '.json')
    require(receipt.is_file(), 'Matching frontend launch receipt is missing')
    value = json.loads(receipt.read_text(encoding='utf-8'))
    require(value.get('launch_id') == launch_id and value.get('status') == 'PASS', 'Frontend launch receipt does not match this kernel')
    require(all(value.get(key) is True for key in ['python_in_science', 'conda_prefix_matches', 'ffmpeg_in_science', 'ffprobe_in_science']), 'Frontend activation was not verified')
    return {'status': 'PASS', 'same_launch_as_kernel': True, 'python_in_science': True, 'ffmpeg_in_science': True, 'ffprobe_in_science': True}


def policy_manager():
    # This module is also loaded by path from a Spyder kernel outside BUNDLE.
    spec = importlib.util.spec_from_file_location('science_policy_runtime', BUNDLE / 'science-manager.py')
    manager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(manager)
    return manager


def package_report_tools():
    shared=BUNDLE/'shared' if (BUNDLE/'shared').is_dir() else BUNDLE.parent/'shared'
    spec=importlib.util.spec_from_file_location('science_package_report',shared/'science_package_report.py')
    tools=importlib.util.module_from_spec(spec);spec.loader.exec_module(tools)
    return tools


def package_selection(prefix):
    manager=policy_manager()
    return package_report_tools().coverage(manager.release(),manager.science_config.defaults(BUNDLE),metadata(prefix).values())


def packages(prefix):
    manager = policy_manager()
    config = manager.release()
    installed = metadata(prefix)
    tools = package_report_tools()
    defaults = manager.science_config.defaults(BUNDLE)
    imports = []
    manager.check_plan({'success': True}, installed, config)
    require(sys.version_info[:2] == (3, 14), 'Python 3.14 is required')
    require(not hasattr(sys, '_is_gil_enabled') or sys._is_gil_enabled(), 'GIL must be enabled')
    modules = ['numpy', 'scipy', 'pandas', 'matplotlib', 'seaborn', 'sympy', 'statsmodels', 'sklearn',
               'skimage', 'cv2', 'PIL', 'imageio', 'xarray', 'h5py', 'netCDF4', 'pyarrow', 'openpyxl',
               'xlsxwriter', 'jupyterlab', 'ipykernel', 'IPython', 'spyder', 'spyder_kernels', 'numba',
               'tqdm', 'pint', 'uncertainties', 'serial', 'pip', 'shapely', 'exifread', 'imageio_ffmpeg']
    package_names = {manager.spec_name(s) for s in config['ScientificPackages']}
    aliases = {'sklearn':'scikit-learn','skimage':'scikit-image','cv2':'opencv','PIL':'pillow','netCDF4':'netcdf4','IPython':'ipython','serial':'pyserial','imageio_ffmpeg':'imageio-ffmpeg','spyder_kernels':'spyder'}
    modules = [name for name in modules if aliases.get(name, name) in package_names]
    for package, module in tools.RELEASE_IMPORTS.items():
        if package in package_names: modules.append(module)
    for name in modules:
        item={'package':aliases.get(name,name).lower(),'module':name,'status':'PASS'}
        try:
            importlib.import_module(name)
        except Exception as exc:
            item['status']='FAIL';imports.append(item)
            failure=AssertionError('Import failed: ' + name + ' (' + type(exc).__name__ + ')')
            failure.package_selection=tools.coverage(config,defaults,installed.values(),imports)
            raise failure from exc
        imports.append(item)
    probes = {}
    if {'numpy','numba'} <= package_names:
        import numpy as np
        import numba
        @numba.njit
        def total(values): return values.sum()
        require(total(np.arange(5)) == 10, 'Numba JIT failed');probes['numba_jit']=True
    if 'pyarrow' in package_names:
        import pyarrow as pa
        require(pa.array([1,2,3]).to_pylist()==[1,2,3], 'Arrow failed');probes['arrow_cpu']=True
    if 'shapely' in package_names:
        import shapely.geometry
        require(shapely.geometry.Point(0,0).buffer(1).area>3, 'GEOS failed');probes['geos']=True
    torch_requests = tools.PYTORCH_REQUESTS & package_names
    if torch_requests:
        backend = tools.pytorch_backend(config['ScientificPackages'])
        probes['pytorch'] = tools.pytorch_probe(torch_requests, backend)
        imports.extend({'package': name, 'module': 'torch', 'status': 'PASS'} for name in sorted(torch_requests))
    return dict(probes, imports=len(modules), package_selection=tools.coverage(config,defaults,installed.values(),imports), versions={name: installed[name]['version'] for name in ['python','opencv','ffmpeg','spyder']})


def video_capabilities(prefix):
    import cv2
    info = cv2.getBuildInformation()
    require(cv2.__version__.split('.')[0] == '5', 'OpenCV 5 required')
    require(re.search(r'GUI:\s+QT6?', info, re.I) is not None and '6.' in info.split('GUI:', 1)[1].split('Video I/O:', 1)[0], 'Qt6 HighGUI build required')
    require(re.search(r'FFMPEG:\s+YES', info), 'OpenCV FFmpeg I/O disabled')
    backends = [cv2.videoio_registry.getBackendName(b) for b in cv2.videoio_registry.getBackends()]
    require('V4L2' in backends and 'FFMPEG' in backends, 'V4L2/FFMPEG backends missing')
    ffmpeg = prefix / 'bin/ffmpeg'
    versions = command([ffmpeg, '-version'])
    require(re.search(r'ffmpeg version 9\.', versions), 'FFmpeg 9 required')
    require('--enable-gpl' in versions, 'GPL build required')
    probe_version = command([prefix / 'bin/ffprobe', '-version'])
    require(re.search(r'ffprobe version 9\.', probe_version), 'FFprobe 9 required')
    for option, names in [('-devices', ['video4linux2', 'lavfi']), ('-encoders', ['ffv1', 'libx264']),
                          ('-muxers', ['matroska', 'tee', 'fifo', 'nut'])]:
        output = command([ffmpeg, '-hide_banner', option])
        for name in names:
            require(name in output, option + ' missing ' + name)
    libraries = json.loads(command([prefix / 'bin/ffprobe', '-v', 'error', '-show_library_versions', '-of', 'json']))
    return {'opencv': cv2.__version__, 'qt6_highgui': True, 'v4l2_compiled': True, 'backends': backends,
            'ffmpeg_gpl9': True, 'libraries': {r['name']: r['major'] for r in libraries['library_versions']}}


def probe_video(prefix, file, expected):
    data = json.loads(command([prefix / 'bin/ffprobe', '-v', 'error', '-select_streams', 'v:0', '-count_frames',
                               '-show_streams', '-show_frames', '-of', 'json', file]))
    stream = data['streams'][0]
    require(stream['codec_name'] == 'ffv1', 'FFV1 required')
    require(int(stream['nb_read_frames']) == expected, 'Wrong frame count')
    pts = [float(frame['best_effort_timestamp_time']) for frame in data['frames']]
    require(len(pts) == expected and all(b > a for a, b in zip(pts, pts[1:])), 'Nonmonotonic PTS')
    return {'frames': expected, 'codec': 'ffv1', 'monotonic_pts': True}


def videos(prefix):
    import cv2
    import numpy as np
    with tempfile.TemporaryDirectory(prefix='science-video-') as tmp:
        first = Path(tmp) / 'ffmpeg.mkv'
        command([prefix / 'bin/ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=64x48:rate=10',
                 '-frames:v', '3', '-c:v', 'ffv1', '-pix_fmt', 'bgr0', '-y', first])
        second = Path(tmp) / 'opencv.mkv'
        writer = cv2.VideoWriter(str(second), cv2.CAP_FFMPEG, cv2.VideoWriter_fourcc(*'FFV1'), 10, (64, 48))
        try:
            require(writer.isOpened(), 'VideoWriter failed to open')
            for frame in range(5):
                writer.write(np.full((48, 64, 3), frame * 40, dtype=np.uint8))
        finally:
            writer.release()
        results = {}
        for file, count in [(first, 3), (second, 5)]:
            results[file.stem] = probe_video(prefix, file, count)
            capture = cv2.VideoCapture(str(file), cv2.CAP_FFMPEG)
            read = 0
            try:
                require(capture.isOpened(), 'VideoCapture failed to open')
                while True:
                    ok, image = capture.read()
                    if not ok:
                        break
                    require(image.shape[:2] == (48, 64), 'Wrong dimensions')
                    if file == second:
                        require(int(np.abs(image.astype(np.int16) - read * 40).max()) == 0, 'FFV1 lossless pixel check failed')
                    read += 1
            finally:
                capture.release()
            require(read == count, 'OpenCV read-back frame count mismatch')
        return results


def kernel(prefix):
    from jupyter_client import KernelManager
    with tempfile.TemporaryDirectory(prefix='science-kernel-') as tmp:
        env = os.environ.copy()
        env.update(IPYTHONDIR=tmp, JUPYTER_CONFIG_DIR=tmp, JUPYTER_RUNTIME_DIR=tmp, MPLCONFIGDIR=tmp)
        manager = KernelManager()
        manager.kernel_spec.argv = [str(prefix / 'bin/python'), '-m', 'spyder_kernels.console', '-f', '{connection_file}']
        client = None
        try:
            manager.start_kernel(env=env, cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            client = manager.client()
            client.start_channels()
            client.wait_for_ready(timeout=80)
            code = "import sys, os, shutil, pathlib, numpy, cv2\np=pathlib.Path(sys.prefix).resolve()\nassert p == pathlib.Path(" + repr(str(prefix)) + ").resolve()\nassert pathlib.Path(os.environ['CONDA_PREFIX']).resolve() == p\nassert pathlib.Path(shutil.which('ffmpeg')).resolve() == p/'bin/ffmpeg'\nassert pathlib.Path(shutil.which('ffprobe')).resolve() == p/'bin/ffprobe'\nassert cv2.__version__.startswith('5.')\nassert int(numpy.arange(5).sum())==10"
            message_id = client.execute(code)
            deadline = time.monotonic() + 60
            while True:
                require(time.monotonic() < deadline, 'Kernel execution timed out')
                reply = client.get_shell_msg(timeout=60)
                if reply['parent_header'].get('msg_id') == message_id:
                    require(reply['content'].get('status') == 'ok', 'Kernel execution failed')
                    break
        finally:
            if client is not None:
                client.stop_channels()
            if manager.has_kernel:
                manager.shutdown_kernel(now=True)
    return {'first_start': True, 'python_in_science': True, 'ffmpeg_in_science': True, 'ffprobe_in_science': True,
            'spyder_kernels_console': True}


def gui(prefix):
    # Preserve the combined Qt5/Qt6 probe when Matplotlib is explicitly requested.
    from qtpy.QtWidgets import QApplication
    manager = policy_manager()
    requested={manager.spec_name(s) for s in manager.release()['ScientificPackages']}
    import cv2
    import numpy as np
    application = QApplication.instance() or QApplication([])
    figure = None
    if 'matplotlib' in requested:
        import matplotlib
        matplotlib.use('QtAgg')
        import matplotlib.pyplot as plt
        figure = plt.figure()
    try:
        if figure is not None:
            plt.plot([0, 1], [0, 1]); plt.show(block=False)
        cv2.namedWindow('Scientific Python automatic HighGUI check', cv2.WINDOW_NORMAL)
        cv2.imshow('Scientific Python automatic HighGUI check', np.zeros((80, 100, 3), np.uint8))
        for _ in range(12):
            application.processEvents(); cv2.waitKey(20)
    finally:
        cv2.destroyAllWindows()
        if figure is not None: plt.close(figure)
        application.processEvents()
    return {'qt_matplotlib': True if figure is not None else 'SKIP: not requested', 'opencv_highgui_window': True, 'platform_forced': False}


STAGES = {'identity': identity, 'packages': packages, 'video_capabilities': video_capabilities,
          'videos': videos, 'kernel': kernel, 'gui': gui}


def startup_report(prefix):
    spec = importlib.util.spec_from_file_location('runtime_startup_test', BUNDLE / 'science_startup.py')
    startup = importlib.util.module_from_spec(spec); spec.loader.exec_module(startup)
    return startup.run(prefix, Path.home() / '.local/bin/science-spyder')


def gui_after_font_repair(prefix):
    with tempfile.TemporaryDirectory(prefix='science-gui-retry-') as temporary:
        env=os.environ.copy();env.update(MPLCONFIGDIR=temporary,JUPYTER_CONFIG_DIR=temporary,IPYTHONDIR=temporary)
        try:
            result=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--prefix',str(prefix),'--stage','gui'],env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=90)
            if result.stderr:print('[gui retry] '+result.stderr,file=sys.stderr,end='',flush=True)
            try:value=json.loads(result.stdout.split('SCIENCE_RESULT=')[-1])
            except ValueError:value={'status':'FAIL','reason':'GUI retry failed without a result','exit_code':result.returncode}
            if result.returncode:value['status']='FAIL'
            return value
        except subprocess.TimeoutExpired:return {'status':'FAIL','reason':'GUI retry timed out after font repair'}


def run_checks(prefix, use_kernel=False, gui_auto=False):
    report = {'schema': 4, 'checks': {}, 'hardware_camera': {'status': 'SKIP', 'reason': 'No hardware access requested'}}
    report['external_tools'] = {name: bool(shutil.which(name)) for name in ['v4l2-ctl', 'udevadm', 'mkvmerge', 'fuser', 'lsusb', 'strace', 'xrandr']}
    report['external_tools']['gnu_time'] = Path('/usr/bin/time').is_file()
    selected = ['identity', 'packages', 'video_capabilities', 'videos']
    if use_kernel:
        selected.append('kernel')
    startup = importlib.util.module_from_spec(startup_spec := importlib.util.spec_from_file_location('runtime_spyder_startup', BUNDLE / 'science_startup.py'))
    startup_spec.loader.exec_module(startup)
    if gui_auto and startup.graphical_session(os.environ):
        selected.append('gui')
    else:
        report['checks']['gui'] = {'status': 'SKIP', 'reason': 'No desktop display or GUI check not requested'}
    for stage in selected:
        try:
            with tempfile.TemporaryDirectory(prefix='science-probe-') as tmp:
                env = os.environ.copy()
                env.update(MPLCONFIGDIR=tmp, JUPYTER_CONFIG_DIR=tmp, IPYTHONDIR=tmp)
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--prefix', str(prefix), '--stage', stage],
                                        env=env, capture_output=True, text=True, encoding='utf-8', errors='replace',
                                        timeout=180 if stage in ['packages', 'kernel'] else 90)
                if result.stderr:
                    print('[' + stage + '] ' + result.stderr, file=sys.stderr, end='', flush=True)
                if result.returncode and 'SCIENCE_RESULT=' not in result.stdout:
                    print('[' + stage + '] ' + result.stdout, file=sys.stderr, end='', flush=True)
                if result.returncode:
                    value = {'status': 'FAIL', 'reason': 'Probe process failed', 'exit_code': result.returncode}
                    try:
                        value = json.loads(result.stdout.split('SCIENCE_RESULT=')[-1])
                    except ValueError:
                        pass
                else:
                    value = json.loads(result.stdout.split('SCIENCE_RESULT=')[-1])
                report['checks'][stage] = value
        except subprocess.TimeoutExpired:
            report['checks'][stage] = {'status': 'FAIL', 'reason': 'Probe timed out'}
        print(stage + ': ' + report['checks'][stage]['status'], flush=True)
    if gui_auto:
        try:
            value = startup_report(prefix)
        except Exception as error:
            value = {'status': 'FAIL', 'reason': str(error), 'fontconfig_validation': {'status': 'PENDING'}}
    else:
        value = {'status': 'SKIP', 'reason': 'Graphical startup check not requested', 'fontconfig_validation': {'status': 'SKIP'}}
    report['checks']['spyder_startup'] = value
    report['checks']['fontconfig_validation'] = value.get('fontconfig_validation', {'status': 'PENDING'})
    if value.get('fontconfig_validation',{}).get('retry_status')=='PASS' and report['checks'].get('gui',{}).get('status')=='FAIL':
        previous=report['checks']['gui'];retried=gui_after_font_repair(prefix)
        retried.update(initial_failure=previous,retried_after_font_repair=True)
        report['checks']['gui']=retried
        print('gui after font repair: '+retried['status'],flush=True)
    print('spyder_startup: ' + value['status'], flush=True)
    report['status'] = 'FAIL' if any(v['status'] in ['FAIL', 'BLOCKED'] for v in report['checks'].values()) else 'PENDING' if any(v['status'] == 'PENDING' for v in report['checks'].values()) else 'PASS'
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--kernel', action='store_true')
    parser.add_argument('--gui-auto', action='store_true')
    parser.add_argument('--stage', choices=STAGES)
    args = parser.parse_args()
    if args.stage:
        try:
            result = {'status': 'PASS', 'details': STAGES[args.stage](args.prefix)}
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            result = {'status': 'FAIL', 'error_type': type(exc).__name__, 'reason': str(exc)[:1000]}
            if args.stage == 'packages':
                try:result['details']={'package_selection':getattr(exc,'package_selection',None) or package_selection(args.prefix)}
                except Exception:pass  # Invalid configuration is already reported as failure.
        print('SCIENCE_RESULT=' + json.dumps(result), flush=True)
        # All probes and kernel resources have been explicitly closed above.
        os._exit(0 if result['status'] == 'PASS' else 1)
    report = run_checks(args.prefix, args.kernel, args.gui_auto)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return 0 if report['status'] in ['PASS', 'PENDING'] else 1


if __name__ == '__main__':
    sys.exit(main())
