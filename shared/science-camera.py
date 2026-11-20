#!/usr/bin/env python3
"""Optional physical camera checks using the selected Science Python and OpenCV."""
import argparse
import errno
import json
import os
from pathlib import Path
import queue
import re
import stat
import struct
import subprocess
import sys
import threading
import time
from dataclasses import dataclass

WINDOWS = sys.platform == 'win32'
BACKEND = 'DirectShow' if WINDOWS else 'V4L2'
VIDEO_NODE = re.compile(r'video([0-9]+)', re.ASCII)
DISCOVERY_SECONDS = 30
WINDOWS_STARTUP_SECONDS = 12
WINDOWS_PREVIEW_INIT_SECONDS = 12
WINDOWS_PREVIEW_SHUTDOWN_SECONDS = 2


def result(status, reason, **details):
    return {'status': status, 'reason': reason, **details}


@dataclass(frozen=True)
class Device:
    target: int | str
    name: str = ''
    capabilities: str = 'unknown'
    precheck: dict | None = None

    @property
    def label(self):
        return f'index {self.target}' if isinstance(self.target, int) else self.target


def access_error(error):
    reason = {errno.EACCES: 'PERMISSION_DENIED', errno.EPERM: 'PERMISSION_DENIED',
              errno.EBUSY: 'DEVICE_BUSY', errno.ENOENT: 'DEVICE_GONE',
              errno.ENODEV: 'DEVICE_GONE'}.get(error.errno, 'DEVICE_ACCESS_FAILED')
    return result('FAIL', reason)


def display_name(name):
    return ''.join(char for char in name if char.isprintable()).strip()


def linux_capabilities(target, writable=False):
    import fcntl

    if linux_target(target) != target:
        return result('UNSUPPORTED', 'NOT_A_VIDEO_DEVICE')
    access = os.O_RDWR if writable else os.O_RDONLY
    try:
        fd = os.open(target, access | os.O_NONBLOCK | os.O_NOFOLLOW)
        try:
            if not stat.S_ISCHR(os.fstat(fd).st_mode):
                return result('UNSUPPORTED', 'NOT_A_VIDEO_DEVICE')
            # Linux x86-64 VIDIOC_QUERYCAP, struct v4l2_capability (104 bytes).
            data = bytearray(104)
            fcntl.ioctl(fd, 0x80685600, data)
        finally:
            os.close(fd)
    except OSError as error:
        if error.errno in (errno.ENOTTY, errno.EINVAL):
            return result('UNSUPPORTED', 'NO_V4L2_INTERFACE')
        return access_error(error)
    name = data[16:48].split(b'\0', 1)[0].decode('utf-8', errors='replace')
    name = display_name(name)
    capabilities, device_caps = struct.unpack_from('=II', data, 84)
    flags = device_caps if capabilities & 0x80000000 else capabilities
    # VIDEO_CAPTURE and VIDEO_CAPTURE_MPLANE, per node when DEVICE_CAPS is set.
    if not flags & 0x1001:
        return result('UNSUPPORTED', 'NO_VIDEO_CAPTURE', name=name,
                      capabilities='metadata only' if flags & 0x00800000 else 'no video capture')
    return result('CANDIDATE', 'VIDEO_CAPTURE', name=name, capabilities='video capture')


def open_cv():
    import cv2

    backend = cv2.CAP_DSHOW if WINDOWS else cv2.CAP_V4L2
    if not Path(cv2.__file__).resolve().is_relative_to(Path(sys.prefix).resolve()):
        raise ImportError('OpenCV is outside the selected Science prefix.')
    if not cv2.videoio_registry.hasBackend(backend):
        raise ImportError('The native OpenCV camera backend is unavailable.')
    return cv2, backend


def enumerate_directshow(cv, backend):
    registry = cv.videoio_registry
    enumerate_devices = getattr(registry, 'enumerateDevices', None)
    if enumerate_devices is None:
        return result('SKIP', 'ENUMERATION_UNAVAILABLE')
    try:
        rows = []
        for device in enumerate_devices(backend):
            if device.backend == backend and 0 <= device.cam_idx <= 99:
                name = display_name(device.cam_name)
                rows.append([device.cam_idx, '' if name == f'cam: {device.cam_idx}' else name])
    except (cv.error, UnicodeError):
        return result('SKIP', 'ENUMERATION_UNAVAILABLE')
    if not rows:
        # Even a built-in DirectShow backend may open an index that the
        # enumeration API did not list.
        return result('SKIP', 'ENUMERATION_EMPTY')
    return result('CANDIDATE', 'ENUMERATED', devices=rows)


def frame_size(ok, frame):
    if not ok or frame is None or not frame.size:
        return None
    shape = frame.shape
    if len(shape) not in (2, 3) or (len(shape) == 3 and shape[2] not in (1, 3, 4)):
        return None
    height, width = shape[:2]
    return (width, height) if width > 0 and height > 0 else None


def preview_frames(cv, capture, frame, target, seconds):
    if not WINDOWS and not (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')):
        return 'PREVIEW_UNAVAILABLE'
    title = f'Scientific Python USB camera - {target}'
    try:
        if hasattr(cv, 'currentUIFramework') and not cv.currentUIFramework():
            return 'PREVIEW_UNAVAILABLE'
        cv.namedWindow(title, cv.WINDOW_NORMAL)
    except Exception:
        return 'PREVIEW_UNAVAILABLE'
    try:
        end = time.monotonic() + seconds
        while True:
            cv.imshow(title, frame)
            if cv.waitKey(1) & 0xff in (27, ord('q'), ord('Q')) or time.monotonic() >= end:
                return 'PREVIEW_COMPLETED'
            ok, frame = capture.read()
            if not frame_size(ok, frame):
                return 'PREVIEW_STREAM_INTERRUPTED'
    except Exception:
        return 'PREVIEW_UNAVAILABLE'
    finally:
        try:
            cv.destroyWindow(title)
        except Exception:
            # The user may have closed the only preview window already.
            pass


def preview_windows(cv, capture, frame, target, seconds, phase, notify):
    """Ready means the first frame was submitted and the GUI event pump returned."""
    title = f'Scientific Python USB camera - {target}'
    timing = {}
    outcome = 'PREVIEW_UNAVAILABLE'
    window_attempted = False

    def measured(step, operation):
        notify({'preview_step': step})
        started = time.monotonic()
        value = operation()
        elapsed = time.monotonic() - started
        timing[step] = round(elapsed, 3)
        notify({'preview_timing': {step: timing[step]}})
        return value

    phase('preview_init')
    init_started = time.monotonic()
    active_started = None
    try:
        if not hasattr(cv, 'currentUIFramework') or measured('ui_backend', cv.currentUIFramework):
            window_attempted = True
            measured('named_window', lambda: cv.namedWindow(title, cv.WINDOW_NORMAL))
            measured('first_imshow', lambda: cv.imshow(title, frame))
            key = measured('first_wait_key', lambda: cv.waitKey(1))
            active_started = time.monotonic()
            timing['initialization'] = round(active_started - init_started, 3)
            notify({'preview_timing': {'initialization': timing['initialization']}})
            phase('preview')
            end = active_started + seconds
            outcome = 'PREVIEW_COMPLETED'
            while key & 0xff not in (27, ord('q'), ord('Q')) and time.monotonic() < end:
                ok, frame = capture.read()
                if not frame_size(ok, frame):
                    outcome = 'PREVIEW_STREAM_INTERRUPTED'
                    break
                if time.monotonic() >= end:
                    break
                cv.imshow(title, frame)
                key = cv.waitKey(1)
    except Exception:
        outcome = 'PREVIEW_UNAVAILABLE' if active_started is None else 'PREVIEW_FAILED'
    finally:
        if active_started is None:
            timing['initialization'] = round(time.monotonic() - init_started, 3)
        else:
            timing['display'] = round(time.monotonic() - active_started, 3)
        notify({'preview_timing': timing.copy()})
        if window_attempted:
            phase('preview_shutdown')
            notify({'preview_outcome': outcome})
            try:
                measured('destroy_window', lambda: cv.destroyWindow(title))
            except Exception:
                outcome = 'PREVIEW_CLEANUP_FAILED'
    return outcome, timing


class CameraCleanupError(RuntimeError):
    def __init__(self, value):
        super().__init__('CAMERA_CLEANUP_FAILED')
        self.value = value


def capture_device(target, options, phase, cv, backend, probe=False, notify=lambda _: None):
    if not WINDOWS:
        # Check again before capture in case a disconnected node was replaced.
        # OpenCV's bool return does not expose errno.
        capabilities = linux_capabilities(target, writable=True)
        if capabilities['status'] != 'CANDIDATE':
            return {key: value for key, value in capabilities.items() if key not in ('name', 'capabilities')}
    capture = cv.VideoCapture()
    captured = {}
    preview_details = {}
    try:
        if not capture.open(target, backend):
            return result('FAIL', 'OPEN_FAILED')
        if probe:
            return result('CANDIDATE', 'OPENED')
        phase('capture')
        end = time.monotonic() + options['capture_timeout']
        consecutive = 0
        had_frames = False
        while time.monotonic() < end:
            ok, frame = capture.read()
            size = frame_size(ok, frame)
            consecutive = consecutive + 1 if size else 0
            had_frames |= size is not None
            if consecutive >= options['frames']:
                captured = dict(width=size[0], height=size[1], frames=consecutive)
                preview = 'NOT_REQUESTED'
                if WINDOWS:
                    notify({'captured': captured})
                if options['preview']:
                    if WINDOWS:
                        preview, timing = preview_windows(cv, capture, frame, target,
                                                          options['preview_seconds'], phase, notify)
                        preview_details = {'preview_timing': timing, 'preview': preview}
                        notify({'preview_outcome': preview})
                        if preview != 'PREVIEW_COMPLETED':
                            return result('FAIL', preview, capture_status='PASS', **captured, **preview_details)
                    else:
                        phase('preview')
                        preview = preview_frames(cv, capture, frame, target, options['preview_seconds'])
                return result('PASS', 'VALID_FRAMES', **captured, **({'preview': preview} | preview_details))
            if not size:
                time.sleep(0.02)
        return result('FAIL', 'STREAM_INTERRUPTED' if had_frames else 'NO_VALID_FRAMES')
    finally:
        phase('shutdown')
        try:
            capture.release()
        except Exception as error:
            if not WINDOWS:
                raise
            # Release overrides a capture/preview success.
            raise CameraCleanupError(result('FAIL', 'CAMERA_CLEANUP_FAILED', **captured, **preview_details,
                                            **({'capture_status': 'PASS'} if captured else {}))) from error


def emit(message):
    print(json.dumps(message), flush=True)


def worker(action, target, options):
    def notify(message):
        if WINDOWS:
            message = {**message, 'time': time.monotonic()}
        emit(message)

    def phase(name):
        notify({'phase': name})
    try:
        if not WINDOWS or action == 'query':
            phase('open')
        if action == 'query':
            value = linux_capabilities(target)
        else:
            try:
                cv, backend = open_cv()
            except (ImportError, OSError):
                notify({'result': result('FAIL', 'BACKEND_UNAVAILABLE')})
                return
            if action == 'enumerate':
                phase('enumerate')
                value = enumerate_directshow(cv, backend)
            else:
                if WINDOWS:
                    phase('open')
                value = capture_device(target, options, phase, cv, backend, probe=action == 'probe', notify=notify)
    except CameraCleanupError as error:
        value = error.value
    except Exception:
        value = result('FAIL', 'WORKER_ERROR')
    notify({'result': value})


def read_messages(pipe, messages):
    try:
        with pipe:
            for line in pipe:
                try:
                    messages.put(json.loads(line))
                except ValueError:
                    continue
    finally:
        messages.put(None)


def stop_worker(process):
    try:
        if process.poll() is None:
            process.kill()
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        return False
    return True


def run_worker(action, target, options, budget=None):
    command = [sys.executable, '-IB', __file__, '--worker', json.dumps([action, target, options])]
    windows_backend = WINDOWS and action != 'query'
    if windows_backend:
        started = time.monotonic()
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, encoding='utf-8', errors='replace',
                               start_new_session=not WINDOWS,
                               creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if WINDOWS else 0)
    messages = queue.Queue()
    # A reader thread only transports messages. Native OpenCV calls run in the
    # child, so a blocked backend never depends on cancelling the thread.
    reader = threading.Thread(target=read_messages, args=(process.stdout, messages), daemon=True)
    reader.start()
    limits = {'open': options['open_timeout'], 'capture': options['capture_timeout'] + 0.2,
              'preview': options['preview_seconds'] + 1, 'shutdown': 1}
    name = 'open'
    if windows_backend:
        limits.update(startup=WINDOWS_STARTUP_SECONDS)
        if action == 'enumerate':
            limits['enumerate'] = limits.pop('open')
        if action == 'test' and options['preview']:
            limits.update(preview_init=options.get('preview_init_timeout', WINDOWS_PREVIEW_INIT_SECONDS),
                          preview_shutdown=WINDOWS_PREVIEW_SHUTDOWN_SECONDS)
        name = 'startup'
    else:
        started = time.monotonic()
    hard_end = started + (budget if budget is not None else sum(limits.values()))
    deadline = min(hard_end, started + limits[name])
    value = None
    captured = {}
    preview_timing = {}
    preview_step = None
    preview_outcome = None

    def failure(reason, **details):
        if captured:
            preview = preview_outcome if name == 'shutdown' and preview_outcome else reason
            details.update(capture_status='PASS', **captured)
            if options['preview']:
                details['preview'] = preview
            if preview_timing:
                details['preview_timing'] = preview_timing
            if name == 'preview_init' and preview_step:
                details['preview_step'] = preview_step
        return result('FAIL', reason, **details)

    try:
        while True:
            message = messages.get(timeout=max(0, deadline - time.monotonic()))
            if message is None:
                reader.join(timeout=0.1)
                if process.wait(timeout=max(0, deadline - time.monotonic())) == 0 and value is not None:
                    return value
                preview_attempt = options['preview'] and (name.startswith('preview') or captured)
                return failure('PREVIEW_WORKER_EXITED' if preview_attempt else 'WORKER_EXITED')
            timestamp = message['time'] if windows_backend and 'time' in message else time.monotonic()
            if windows_backend and timestamp > deadline:
                # The worker and parent use the same Windows monotonic clock.
                # A late phase transition may not extend an expired deadline.
                raise queue.Empty
            if 'captured' in message:
                captured = message['captured']
            if 'preview_timing' in message:
                preview_timing.update(message['preview_timing'])
            if 'preview_step' in message:
                preview_step = message['preview_step']
            if 'preview_outcome' in message:
                preview_outcome = message['preview_outcome']
            if 'phase' in message and message['phase'] != name:
                name = message['phase']
                deadline = min(hard_end, timestamp + limits[name])
            if 'result' in message:
                value = message['result']
    except KeyboardInterrupt:
        terminated = stop_worker(process)
        if captured:
            return failure('USER_CANCELLED', worker_terminated=terminated) | {'status': 'SKIP'}
        return result('SKIP', 'USER_CANCELLED', worker_terminated=terminated)
    except (queue.Empty, subprocess.TimeoutExpired):
        return failure(name.upper() + '_TIMEOUT', worker_terminated=stop_worker(process))
    except BaseException:
        stop_worker(process)
        raise


def linux_nodes(directory=Path('/dev')):
    return sorted((str(path) for path in directory.glob('video*') if VIDEO_NODE.fullmatch(path.name)),
                  key=lambda path: int(Path(path).name[5:]))


def linux_target(value, directory=Path('/dev')):
    if value.isascii() and value.isdecimal():
        value = str(directory / ('video' + value))
    path = Path(value)
    if path.parent == directory / 'v4l/by-id' and path.is_symlink():
        path = path.resolve(strict=True)
    if path.parent != directory or not VIDEO_NODE.fullmatch(path.name):
        raise ValueError('Select a /dev/videoN node, a numeric node suffix or a /dev/v4l/by-id/ link.')
    return str(path)


def identify_linux(target, options, budget=None):
    value = run_worker('query', target, options, budget)
    info = value.pop('capabilities', 'unknown')
    name = value.pop('name', '')
    return Device(target, name, info, None if value['status'] == 'CANDIDATE' else value)


def discover(options):
    targets = range(options['probe_limit']) if WINDOWS else linux_nodes()
    devices = []
    enumeration_timeout = None
    end = time.monotonic() + DISCOVERY_SECONDS
    if WINDOWS:
        # Reserve part of the aggregate budget for index probes even if the
        # native list operation stalls.
        value = run_worker('enumerate', None, options, DISCOVERY_SECONDS / 2)
        if value['reason'] == 'ENUMERATED' and value['devices']:
            names = {index: name for index, name in value['devices']}
            return [Device(index, names[index]) for index in sorted(names)], None
        if value['reason'] == 'ENUMERATE_TIMEOUT' and not value.get('worker_terminated'):
            return [], value
        if value['reason'] not in ('ENUMERATED', 'ENUMERATION_EMPTY',
                                   'ENUMERATION_UNAVAILABLE', 'ENUMERATE_TIMEOUT'):
            return [], value
        if value['reason'] == 'ENUMERATE_TIMEOUT':
            enumeration_timeout = value
    for target in targets:
        remaining = end - time.monotonic()
        if remaining <= 0:
            return devices, result('SKIP', 'DISCOVERY_INCOMPLETE')
        if WINDOWS:
            value = run_worker('probe', target, options, remaining)
            if value['reason'] == 'OPEN_FAILED':
                # DirectShow cannot distinguish an absent index from an index that won't open.
                continue
            if value['reason'] in ('BACKEND_UNAVAILABLE', 'USER_CANCELLED'):
                return devices, value
            devices.append(Device(target, precheck=None if value['status'] == 'CANDIDATE' else value))
            if value.get('worker_terminated') is False:
                return devices, result('SKIP', 'DISCOVERY_INCOMPLETE')
        else:
            device = identify_linux(target, options, remaining)
            if device.precheck and device.precheck['reason'] == 'USER_CANCELLED':
                return devices, device.precheck
            devices.append(device)
    return devices, None if devices else enumeration_timeout


def test_device(device, options):
    value = device.precheck if device.precheck is not None else run_worker('test', device.target, options)
    return {**value, 'device': device.label, 'backend': BACKEND, 'capabilities': device.capabilities}


def test_all(devices, options):
    rows = []
    for device in devices:
        row = test_device(device, options)
        rows.append(row)
        if row['reason'] == 'USER_CANCELLED':
            rows.extend({**result('SKIP', 'USER_CANCELLED'), 'device': pending.label,
                         'backend': BACKEND, 'capabilities': pending.capabilities}
                        for pending in devices[len(rows):])
            break
    return rows


def show_devices(devices, output=None):
    output = sys.stderr if output is None else output
    for number, device in enumerate(devices, 1):
        name = f' ({device.name})' if device.name else ''
        status = device.precheck['reason'] if device.precheck else 'candidate'
        print(f'{number:2d}  {device.label}{name}  {BACKEND}  {device.capabilities}  {status}', file=output)


def interactive(devices, diagnostic, options):
    while True:
        show_devices(devices)
        if diagnostic:
            print(diagnostic['reason'], file=sys.stderr)
        if diagnostic and diagnostic['reason'] == 'USER_CANCELLED':
            return [], diagnostic
        if not devices and not diagnostic:
            print('No camera candidates found.', file=sys.stderr)
        print('Number: test one  A: test all  R: refresh  Q: quit', file=sys.stderr)
        try:
            choice = input('Selection: ').strip().lower()
        except (EOFError, KeyboardInterrupt):
            choice = 'q'
        if choice == 'q':
            return [], result('SKIP', 'USER_CANCELLED')
        if choice == 'r':
            devices, diagnostic = discover(options)
        elif choice == 'a':
            return test_all(devices, options), diagnostic
        elif re.fullmatch(r'[0-9]{1,6}', choice) and 1 <= int(choice) <= len(devices):
            return [test_device(devices[int(choice) - 1], options)], diagnostic


def bounded(minimum, maximum, convert):
    def parse(value):
        number = convert(value)
        if not minimum <= number <= maximum:
            raise argparse.ArgumentTypeError(f'Expected a value from {minimum} to {maximum}.')
        return number
    return parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, required=True, help=argparse.SUPPRESS)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--list', action='store_true', help='List camera candidates without checking frames.')
    selection.add_argument('--device', help='DirectShow index, /dev/videoN node or Linux by-id link.')
    selection.add_argument('--all', action='store_true', help='Test each detected candidate independently.')
    preview = parser.add_mutually_exclusive_group()
    preview.add_argument('--preview', dest='preview', action='store_true')
    preview.add_argument('--no-preview', dest='preview', action='store_false')
    parser.set_defaults(preview=None)
    parser.add_argument('--frames', type=bounded(2, 120, int), default=3)
    parser.add_argument('--open-timeout', type=bounded(0.5, 30, float), default=4,
                        help='Seconds for device open (Windows: also for native enumeration; startup is separate).')
    parser.add_argument('--capture-timeout', type=bounded(0.5, 60, float), default=4)
    parser.add_argument('--preview-seconds', type=bounded(1, 60, float), default=5)
    if WINDOWS:
        parser.add_argument('--preview-init-timeout', type=bounded(0.5, 30, float),
                            default=WINDOWS_PREVIEW_INIT_SECONDS,
                            help='Seconds allowed for initial preview window, image and GUI events.')
    parser.add_argument('--probe-limit', type=bounded(1, 100, int), default=16, help='Windows: upper bound on indexes to probe.')
    parser.add_argument('--json', action='store_true', help='Write redacted result JSON to stdout.')
    args = parser.parse_args()
    if args.prefix.resolve() != Path(sys.prefix).resolve():
        parser.exit(1, 'Camera test requires the selected Science interpreter.\n')
    cli = args.list or args.all or args.device is not None or args.json
    if not cli and not sys.stdin.isatty():
        parser.error('Choose --list, --all or --device for unattended operation.')
    options = vars(args).copy()
    del options['prefix']
    options['preview'] = args.preview if args.preview is not None else not cli
    if not cli:
        print('Scientific Python USB Camera Test', file=sys.stderr)
    diagnostic = None
    if args.device is not None:
        try:
            if WINDOWS and not re.fullmatch(r'[0-9]{1,2}', args.device):
                raise ValueError('Select a DirectShow index from 0 to 99.')
            device = Device(int(args.device)) if WINDOWS else identify_linux(linux_target(args.device), options)
        except (ValueError, OSError) as error:
            parser.error(str(error) if isinstance(error, ValueError) else 'The selected camera path is unavailable.')
        rows = [test_device(device, options)]
    else:
        devices, diagnostic = discover(options)
        if args.list:
            rows = [{**(device.precheck or result('SKIP', 'LIST_ONLY')), 'device': device.label,
                     'backend': BACKEND, 'capabilities': device.capabilities} for device in devices]
        elif args.all or args.json:
            rows = test_all(devices, options) if not diagnostic or diagnostic['reason'] != 'USER_CANCELLED' else []
        else:
            rows, diagnostic = interactive(devices, diagnostic, options)
    if not rows and not diagnostic:
        diagnostic = result('SKIP', 'NO_CAMERA')
    status = 'FAIL' if any(row['status'] == 'FAIL' for row in rows + ([diagnostic] if diagnostic else [])) else (
        'PASS' if any(row['status'] == 'PASS' for row in rows) else 'SKIP')
    if args.json:
        print(json.dumps({'status': status, 'devices': rows, 'diagnostic': diagnostic}, indent=2))
    else:
        if args.list:
            show_devices(devices, output=sys.stdout)
        for row in ([] if args.list else rows):
            resolution = f", {row['width']}x{row['height']}, {row['frames']} consecutive frames" if 'width' in row else ''
            if row.get('preview') and row['preview'] != row['reason']:
                resolution += f", {row['preview']}"
            if row.get('preview_step'):
                resolution += f", last preview step: {row['preview_step']}"
            if row.get('capture_status') == 'PASS' and row['status'] != 'PASS':
                resolution += ', capture passed'
            cleanup = f", worker terminated: {row['worker_terminated']}" if 'worker_terminated' in row else ''
            print(f"{row['device']} [{BACKEND}]: {row['status']} ({row['reason']}{resolution}{cleanup})")
        if diagnostic:
            print(f"{diagnostic['status']}: {diagnostic['reason']}")
        print(f'Camera test: {status}')
    return {'PASS': 0, 'FAIL': 1, 'SKIP': 2}[status]


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--worker':
        worker(*json.loads(sys.argv[2]))
    else:
        raise SystemExit(main())
