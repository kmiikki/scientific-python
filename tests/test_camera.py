"""Camera regressions with simulated backends and real process timeouts."""
import contextlib
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('science_camera', ROOT / 'shared/science-camera.py')
camera = importlib.util.module_from_spec(spec)
spec.loader.exec_module(camera)
OPTIONS = dict(frames=3, open_timeout=1, capture_timeout=0.02, preview=False, preview_seconds=1, probe_limit=8)
FRAME = SimpleNamespace(size=192, shape=(8, 8, 3))


class CameraTests(unittest.TestCase):
    def capture(self, samples=(), options=None, opened=True):
        capture = Mock()
        capture.open.return_value = opened
        capture.read.side_effect = samples
        cv = Mock()
        cv.VideoCapture.return_value = capture
        phases = []
        with patch.object(camera, 'WINDOWS', True):
            value = camera.capture_device(4, options or OPTIONS, phases.append, cv, 700)
        capture.open.assert_called_once_with(4, 700)
        capture.release.assert_called_once()
        self.assertEqual(phases[-1], 'shutdown')
        return value, cv

    def test_no_camera_has_skip_exit_and_json(self):
        with patch.object(camera, 'WINDOWS', False), patch.object(camera, 'linux_nodes', return_value=[]):
            output = io.StringIO()
            argv = ['camera', '--prefix', sys.prefix, '--all', '--json']
            with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(output):
                self.assertEqual(camera.main(), 2)
            self.assertEqual(json.loads(output.getvalue())['diagnostic'], camera.result('SKIP', 'NO_CAMERA'))

    def test_static_dark_frames_pass_with_measured_resolution(self):
        value, _ = self.capture([(True, FRAME)] * 3)
        self.assertEqual(value, camera.result('PASS', 'VALID_FRAMES', width=8, height=8,
                                              frames=3, preview='NOT_REQUESTED'))

    def test_sparse_directshow_discovery_and_all(self):
        def fake_worker(action, index, _options, _budget=None):
            if action == 'enumerate':
                return camera.result('SKIP', 'ENUMERATION_UNAVAILABLE')
            if action == 'test' and index in (2, 7):
                return camera.result('PASS', 'VALID_FRAMES')
            if action == 'probe' and index in (2, 7):
                return camera.result('CANDIDATE', 'OPENED')
            return camera.result('FAIL', 'OPEN_FAILED')

        with patch.object(camera, 'WINDOWS', True), patch.object(camera, 'run_worker', side_effect=fake_worker):
            devices, diagnostic = camera.discover(OPTIONS)
            rows = camera.test_all(devices, OPTIONS)
        self.assertIsNone(diagnostic)
        self.assertEqual([device.target for device in devices], [2, 7])
        self.assertEqual([row['status'] for row in rows], ['PASS', 'PASS'])
        self.assertEqual([device.name for device in devices], ['', ''])

    def test_directshow_native_names_use_the_reported_backend_and_index(self):
        registry = Mock()
        registry.enumerateDevices.return_value = [
            SimpleNamespace(backend=700, cam_idx=8, cam_name='Dock camera'),
            SimpleNamespace(backend=700, cam_idx=3, cam_name='cam: 3'),
            SimpleNamespace(backend=1400, cam_idx=4, cam_name='Other backend'),
        ]
        value = camera.enumerate_directshow(SimpleNamespace(videoio_registry=registry), 700)
        registry.enumerateDevices.assert_called_once_with(700)
        with patch.object(camera, 'WINDOWS', True), patch.object(camera, 'run_worker', return_value=value) as run:
            devices, diagnostic = camera.discover(OPTIONS)
        self.assertEqual([(d.target, d.name) for d in devices], [(3, ''), (8, 'Dock camera')])
        self.assertIsNone(diagnostic)
        run.assert_called_once()

    def test_directshow_empty_native_list_uses_bounded_probes_in_each_mode(self):
        registry = Mock()
        registry.enumerateDevices.return_value = []
        registry.isBackendBuiltIn.return_value = True
        cv = Mock(videoio_registry=registry)
        cap = cv.VideoCapture.return_value
        cap.open.side_effect = lambda index, _backend: index == 0
        cap.read.return_value = True, SimpleNamespace(size=640 * 480 * 3, shape=(480, 640, 3))

        def fake_worker(action, index, options, budget=None):
            if action == 'enumerate':
                return camera.enumerate_directshow(cv, 700)
            return camera.capture_device(index, options, lambda _: None, cv, 700, probe=action == 'probe')

        for args, code, actions, expected in [
            (['--list', '--json'], 2, [('enumerate', None), ('probe', 0), ('probe', 1)], 'LIST_ONLY'),
            (['--all', '--json'], 0, [('enumerate', None), ('probe', 0), ('probe', 1), ('test', 0)], 'VALID_FRAMES'),
            ([], 0, [('enumerate', None), ('probe', 0), ('probe', 1), ('test', 0)], 'VALID_FRAMES'),
            (['--device', '0', '--json'], 0, [('test', 0)], 'VALID_FRAMES'),
            (['--device', '1', '--json'], 1, [('test', 1)], 'OPEN_FAILED'),
        ]:
            output = io.StringIO()
            argv = ['camera', '--prefix', sys.prefix, '--probe-limit', '2', '--no-preview', *args]
            with self.subTest(args=args), patch.object(camera, 'WINDOWS', True), \
                 patch.object(camera, 'BACKEND', 'DirectShow'), patch.object(sys, 'argv', argv), \
                 patch.object(sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='1'), \
                 contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()), \
                 patch.object(camera, 'run_worker', side_effect=fake_worker) as run:
                self.assertEqual(camera.main(), code)
                self.assertEqual([call.args[:2] for call in run.call_args_list], actions)
                if '--json' in args:
                    report = json.loads(output.getvalue())
                    self.assertIsNone(report['diagnostic'])
                    row, = report['devices']
                    self.assertEqual(row['device'], 'index 1' if expected == 'OPEN_FAILED' else 'index 0')
                    self.assertEqual(row['reason'], expected)
                    if expected == 'VALID_FRAMES':
                        self.assertEqual((row['width'], row['height'], row['frames']), (640, 480, 3))
                else:
                    self.assertIn('index 0 [DirectShow]: PASS (VALID_FRAMES, 640x480', output.getvalue())

    def test_directshow_enumeration_timeout_leaves_budget_for_fallback(self):
        options = OPTIONS | {'probe_limit': 1}
        timeout = camera.result('FAIL', 'ENUMERATE_TIMEOUT', worker_terminated=True)
        with patch.object(camera, 'WINDOWS', True), patch.object(camera.time, 'monotonic', side_effect=[0, 15]):
            with patch.object(camera, 'run_worker', side_effect=[timeout, camera.result('CANDIDATE', 'OPENED')]) as run:
                devices, diagnostic = camera.discover(options)
        self.assertEqual([call.args[-1] for call in run.call_args_list], [15, 15])
        self.assertEqual([d.target for d in devices], [0])
        self.assertIsNone(diagnostic)

    def test_directshow_discovery_does_not_mask_unresolved_timeout_as_no_camera(self):
        options = OPTIONS | {'probe_limit': 1}
        for terminated in (False, True):
            timeout = camera.result('FAIL', 'ENUMERATE_TIMEOUT', worker_terminated=terminated)
            outcomes = [timeout, camera.result('FAIL', 'OPEN_FAILED')]
            with self.subTest(terminated=terminated), patch.object(camera, 'WINDOWS', True), \
                 patch.object(camera, 'run_worker', side_effect=outcomes) as run:
                self.assertEqual(camera.discover(options), ([], timeout))
                self.assertEqual(run.call_count, 2 if terminated else 1)

    def test_windows_startup_does_not_consume_camera_open_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'phase.py'
            script.write_text(
                "import json, sys, time\n"
                "action = json.loads(sys.argv[2])[0]\n"
                "time.sleep(0.5)\n"
                "print(json.dumps({'phase': 'enumerate' if action == 'enumerate' else 'open'}), flush=True)\n"
                "if action != 'ready': time.sleep(60)\n"
                "print(json.dumps({'result': {'status': 'CANDIDATE', 'reason': 'OPENED'}}), flush=True)\n",
                encoding='ascii')
            options = OPTIONS | {'open_timeout': 0.3}
            with patch.object(camera, 'WINDOWS', True), patch.object(camera, '__file__', str(script)), \
                 patch.object(subprocess, 'CREATE_NEW_PROCESS_GROUP',
                              getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0), create=True):
                self.assertEqual(camera.run_worker('ready', 0, options)['reason'], 'OPENED')
                for action, reason in [('probe', 'OPEN_TIMEOUT'), ('enumerate', 'ENUMERATE_TIMEOUT')]:
                    with self.subTest(action=action):
                        self.assertEqual(camera.run_worker(action, 0, options),
                                         camera.result('FAIL', reason, worker_terminated=True))
                with patch.object(camera, 'WINDOWS_STARTUP_SECONDS', 0.2):
                    self.assertEqual(camera.run_worker('probe', 0, options),
                                     camera.result('FAIL', 'STARTUP_TIMEOUT', worker_terminated=True))

    def test_windows_worker_announces_native_operation_after_backend_initialization(self):
        registry = Mock()
        registry.enumerateDevices.return_value = []
        cv = Mock(videoio_registry=registry)
        cv.VideoCapture.return_value.open.return_value = False
        for action, phases in [('enumerate', ['enumerate']), ('probe', ['open', 'shutdown'])]:
            with self.subTest(action=action), patch.object(camera, 'WINDOWS', True), \
                 patch.object(camera, 'emit') as emit:
                def initialize():
                    emit.assert_not_called()
                    return cv, 700
                with patch.object(camera, 'open_cv', side_effect=initialize):
                    camera.worker(action, 0, OPTIONS)
                self.assertEqual([call.args[0]['phase'] for call in emit.call_args_list[:-1]], phases)
                self.assertIn('result', emit.call_args_list[-1].args[0])

    def test_directshow_discovery_deadline(self):
        with patch.object(camera, 'WINDOWS', True), patch.object(camera.time, 'monotonic', side_effect=[0, 0, 31]):
            with patch.object(camera, 'run_worker', side_effect=[camera.result('SKIP', 'ENUMERATION_UNAVAILABLE'),
                                                                 camera.result('FAIL', 'OPEN_FAILED')]) as run:
                _, diagnostic = camera.discover(OPTIONS)
        self.assertEqual(diagnostic['reason'], 'DISCOVERY_INCOMPLETE')
        self.assertEqual([call.args[0] for call in run.call_args_list], ['enumerate', 'probe'])

    def test_mixed_results_and_prechecked_devices_are_independent(self):
        devices = [
            camera.Device(1),
            camera.Device(4, name='Fingerprint reader', precheck=camera.result('UNSUPPORTED', 'NO_VIDEO_CAPTURE')),
            camera.Device(8, precheck=camera.result('FAIL', 'PERMISSION_DENIED')),
            camera.Device(9),
        ]
        with patch.object(camera, 'run_worker', side_effect=[camera.result('FAIL', 'OPEN_FAILED'),
                                                             camera.result('PASS', 'VALID_FRAMES')]) as run:
            rows = camera.test_all(devices, OPTIONS)
        self.assertEqual([row['status'] for row in rows], ['FAIL', 'UNSUPPORTED', 'FAIL', 'PASS'])
        self.assertNotIn('Fingerprint', json.dumps(rows))
        self.assertEqual([call.args[1] for call in run.call_args_list], [1, 9])

    @unittest.skipUnless(sys.platform.startswith('linux'), 'V4L2 capability fixtures use Linux ioctl')
    def test_v4l2_per_node_caps_for_one_physical_device(self):
        def capability(node, flags):
            def query(_fd, request, data):
                self.assertEqual(request, 0x80685600)
                data[16:22] = b'Webcam'
                struct.pack_into('=II', data, 84, 0x80800001, flags)
            with patch.object(camera.os, 'open', return_value=9), patch.object(camera.os, 'close') as close, \
                 patch.object(camera.os, 'fstat', return_value=SimpleNamespace(st_mode=stat.S_IFCHR)), \
                 patch('fcntl.ioctl', side_effect=query):
                value = camera.linux_capabilities(node)
            close.assert_called_once_with(9)
            return value

        self.assertEqual(capability('/dev/video2', 1)['status'], 'CANDIDATE')
        metadata = capability('/dev/video7', 0x00800000)
        self.assertEqual((metadata['status'], metadata['name'], metadata['capabilities']),
                         ('UNSUPPORTED', 'Webcam', 'metadata only'))

    @unittest.skipUnless(sys.platform.startswith('linux'), 'V4L2 access fixtures use Linux flags')
    def test_permission_busy_and_unknown_access_are_distinguished(self):
        for number, reason in ((errno.EACCES, 'PERMISSION_DENIED'), (errno.EBUSY, 'DEVICE_BUSY'),
                               (errno.ENOTTY, 'NO_V4L2_INTERFACE'), (errno.EIO, 'DEVICE_ACCESS_FAILED')):
            with self.subTest(reason=reason), patch.object(camera.os, 'open', side_effect=OSError(number, 'fixture')):
                self.assertEqual(camera.linux_capabilities('/dev/video4')['reason'], reason)

    def test_v4l2_node_paths_and_aliases_are_deduplicated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'video7').touch()
            (root / 'video2').touch()
            by_id = root / 'v4l/by-id'
            by_id.mkdir(parents=True)
            alias = by_id / 'video-device-serial'
            try:
                alias.symlink_to(root / 'video7')
            except OSError:
                self.skipTest('Symlink creation requires additional permissions on this host.')
            self.assertEqual(camera.linux_nodes(root), [str(root / 'video2'), str(root / 'video7')])
            self.assertEqual(camera.linux_target(str(alias), root), str(root / 'video7'))
            with self.assertRaises(ValueError):
                camera.linux_target(str(root / 'other-file'), root)

    def test_open_failed_has_no_capture(self):
        value, cv = self.capture(opened=False)
        self.assertEqual(value['reason'], 'OPEN_FAILED')
        cv.VideoCapture.return_value.read.assert_not_called()

    def test_native_operation_timeouts_terminate_only_the_child(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'block.py'
            script.write_text("import json, sys, time\nphase = json.loads(sys.argv[2])[0]\n"
                              "print(json.dumps({'phase': phase}), flush=True)\ntime.sleep(60)\n")
            options = OPTIONS | {'open_timeout': 0.3, 'capture_timeout': 0.1}
            with patch.object(camera, '__file__', str(script)):
                for stage in ('open', 'capture', 'shutdown'):
                    with self.subTest(stage=stage):
                        value = camera.run_worker(stage, 1, options)
                        self.assertEqual(value, camera.result('FAIL', stage.upper() + '_TIMEOUT',
                                                              worker_terminated=True))

    def test_no_valid_frames_and_camera_stops_mid_test(self):
        for samples, reason in (([], 'NO_VALID_FRAMES'), ([(True, FRAME)] * 2, 'STREAM_INTERRUPTED')):
            with self.subTest(reason=reason):
                value, _ = self.capture(samples + [(False, None)] * 20)
                self.assertEqual(value['reason'], reason)
        self.assertIsNone(camera.frame_size(True, SimpleNamespace(size=0, shape=(0, 0))))
        self.assertIsNone(camera.frame_size(True, SimpleNamespace(size=8, shape=(1, 1, 8))))

    def test_headless_capture_passes_without_a_window(self):
        with patch.object(camera, 'WINDOWS', False), patch.dict(os.environ, {}, clear=True):
            cv = Mock()
            self.assertEqual(camera.preview_frames(cv, Mock(), FRAME, '/dev/video0', 1), 'PREVIEW_UNAVAILABLE')
            cv.namedWindow.assert_not_called()

    def test_failed_preview_keeps_capture_result_and_releases_device(self):
        with patch.object(camera, 'preview_windows', return_value=('PREVIEW_UNAVAILABLE', {'initialization': 0.1})):
            value, _ = self.capture([(True, FRAME)] * 3, OPTIONS | {'preview': True})
        self.assertEqual((value['status'], value['capture_status'], value['frames'], value['preview']),
                         ('FAIL', 'PASS', 3, 'PREVIEW_UNAVAILABLE'))
        cv = Mock()
        cv.namedWindow.side_effect = RuntimeError('GUI unavailable')
        with patch.object(camera, 'WINDOWS', True):
            self.assertEqual(camera.preview_frames(cv, Mock(), FRAME, 3, 1), 'PREVIEW_UNAVAILABLE')
        cv.imshow.assert_not_called()

    def test_preview_quits_with_q_and_removes_window(self):
        cv = Mock()
        capture = Mock()
        cv.waitKey.return_value = ord('q')
        with patch.object(camera, 'WINDOWS', True):
            self.assertEqual(camera.preview_frames(cv, capture, FRAME, 3, 1), 'PREVIEW_COMPLETED')
        title = 'Scientific Python USB camera - 3'
        cv.imshow.assert_called_once_with(title, FRAME)
        cv.destroyWindow.assert_called_once_with(title)
        capture.read.assert_not_called()

    def test_windows_preview_starts_display_clock_after_first_event_pump(self):
        cv = Mock()
        capture = Mock()
        capture.read.return_value = True, FRAME
        for init_delay in (0.1, 8.0, 0.05):  # fast, cold, then warm
            with self.subTest(init_delay=init_delay):
                now = [0.0]
                phases = []
                messages = []
                def wait_key(_):
                    now[0] += init_delay if not phases or phases[-1][0] == 'preview_init' else 0.25
                    return -1
                cv.waitKey.side_effect = wait_key
                with patch.object(camera.time, 'monotonic', side_effect=lambda: now[0]):
                    outcome, timing = camera.preview_windows(
                        cv, capture, FRAME, 0, 1, lambda stage: phases.append((stage, now[0])), messages.append)
                self.assertEqual(outcome, 'PREVIEW_COMPLETED')
                self.assertEqual(timing['initialization'], init_delay)
                self.assertEqual(timing['first_wait_key'], init_delay)
                self.assertEqual(timing['display'], 1)
                self.assertEqual([name for name, _ in phases], ['preview_init', 'preview', 'preview_shutdown'])
                self.assertEqual(phases[1][1], init_delay)

    def test_windows_preview_esc_and_q_close_after_initial_events(self):
        for key in (27, ord('q'), ord('Q')):
            with self.subTest(key=key):
                cv = Mock()
                cv.waitKey.return_value = key
                capture = Mock()
                outcome, _ = camera.preview_windows(cv, capture, FRAME, 0, 5, Mock(), Mock())
                self.assertEqual(outcome, 'PREVIEW_COMPLETED')
                cv.imshow.assert_called_once()
                cv.destroyWindow.assert_called_once()
                capture.read.assert_not_called()

    def test_windows_preview_failure_keeps_frame_details_in_json_and_cli(self):
        value = camera.result('FAIL', 'PREVIEW_INIT_TIMEOUT', capture_status='PASS',
                              width=640, height=480, frames=3, preview='PREVIEW_INIT_TIMEOUT',
                              preview_step='first_imshow', worker_terminated=True)
        for json_mode in (True, False):
            argv = ['camera', '--prefix', sys.prefix, '--device', '0', '--preview']
            with self.subTest(json_mode=json_mode), patch.object(camera, 'WINDOWS', True), \
                 patch.object(camera, 'BACKEND', 'DirectShow'), \
                 patch.object(sys, 'argv', argv + (['--json'] if json_mode else [])), \
                 patch.object(camera, 'run_worker', return_value=value), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(camera.main(), 1)
                if json_mode:
                    row, = json.loads(output.getvalue())['devices']
                    self.assertEqual({k: row[k] for k in value}, value)
                else:
                    self.assertIn('640x480, 3 consecutive frames', output.getvalue())
                    self.assertIn('last preview step: first_imshow, capture passed', output.getvalue())
                    self.assertIn('Camera test: FAIL', output.getvalue())

    def test_windows_preview_process_boundaries_preserve_captured_frames(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'preview-worker.py'
            script.write_text(f'''
import importlib.util, json, os, sys, time
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("camera", {camera.__file__!r})
camera = importlib.util.module_from_spec(spec)
spec.loader.exec_module(camera)
camera.WINDOWS = True
action, target, options = json.loads(sys.argv[2])
mode = options["fixture_mode"]
frame = SimpleNamespace(size=640 * 480 * 3, shape=(480, 640, 3))
def operation(name):
    if mode == name:
        time.sleep(60)
class Capture:
    reads = 0
    def open(self, *args): return True
    def read(self):
        self.reads += 1
        if self.reads > 3:
            operation("active_read")
            if mode == "exit": os._exit(3)
            time.sleep(0.01)
        return True, frame
    def release(self):
        operation("release")
        if mode == "release_error": raise OSError()
class CV:
    WINDOW_NORMAL = 0
    VideoCapture = Capture
    def currentUIFramework(self): return "fixture"
    def namedWindow(self, *args):
        if mode == "slow": time.sleep(0.55)
    def imshow(self, *args): operation("imshow")
    def waitKey(self, *args):
        operation("waitKey")
        return -1
    def destroyWindow(self, *args): operation("destroy")
camera.open_cv = lambda: (CV(), 700)
camera.worker(action, target, options)
''', encoding='utf-8')
            options = OPTIONS | {'preview': True, 'preview_seconds': 0.3, 'preview_init_timeout': 0.35,
                                 'capture_timeout': 0.2}
            with patch.object(camera, 'WINDOWS', True), patch.object(camera, '__file__', str(script)), \
                 patch.object(subprocess, 'CREATE_NEW_PROCESS_GROUP',
                              getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0), create=True):
                slow = camera.run_worker('test', 0, options | {'fixture_mode': 'slow', 'preview_init_timeout': 2})
                warm = camera.run_worker('test', 0, options | {'fixture_mode': 'warm'})
                for value in (slow, warm):
                    self.assertEqual((value['status'], value['frames'], value['preview']),
                                     ('PASS', 3, 'PREVIEW_COMPLETED'))
                    self.assertGreaterEqual(value['preview_timing']['display'], 0.3)
                self.assertGreaterEqual(slow['preview_timing']['initialization'], 0.5)
                cases = [
                    ('imshow', 'PREVIEW_INIT_TIMEOUT', 'first_imshow', True),
                    ('waitKey', 'PREVIEW_INIT_TIMEOUT', 'first_wait_key', True),
                    ('active_read', 'PREVIEW_TIMEOUT', None, True),
                    ('destroy', 'PREVIEW_SHUTDOWN_TIMEOUT', None, True),
                    ('release', 'SHUTDOWN_TIMEOUT', None, True),
                    ('exit', 'PREVIEW_WORKER_EXITED', None, False),
                    ('release_error', 'CAMERA_CLEANUP_FAILED', None, False),
                ]
                for mode, reason, step, terminated in cases:
                    with self.subTest(mode=mode):
                        value = camera.run_worker('test', 0, options | {'fixture_mode': mode})
                        self.assertEqual((value['status'], value['reason'], value['capture_status']),
                                         ('FAIL', reason, 'PASS'))
                        self.assertEqual((value['width'], value['height'], value['frames']), (640, 480, 3))
                        self.assertEqual(value.get('preview_step'), step)
                        self.assertEqual(value.get('worker_terminated', False), terminated)

    def test_cancellation_marks_remaining_devices_skipped(self):
        devices = [camera.Device(1), camera.Device(3), camera.Device(8)]
        with patch.object(camera, 'run_worker', side_effect=[camera.result('PASS', 'VALID_FRAMES'),
                                                             camera.result('SKIP', 'USER_CANCELLED')]) as run:
            rows = camera.test_all(devices, OPTIONS)
        self.assertEqual([row['status'] for row in rows], ['PASS', 'SKIP', 'SKIP'])
        self.assertEqual(run.call_count, 2)
        with patch('builtins.input', side_effect=KeyboardInterrupt), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(camera.interactive(devices, None, OPTIONS)[1]['reason'], 'USER_CANCELLED')

    def test_release_when_capture_raises(self):
        cv = Mock()
        cap = cv.VideoCapture.return_value
        cap.read.side_effect = RuntimeError('backend failure')
        with patch.object(camera, 'WINDOWS', True), self.assertRaises(RuntimeError):
            camera.capture_device(4, OPTIONS, lambda _: None, cv, 700)
        cap.release.assert_called_once()

    def test_normal_runtime_paths_have_no_camera_entry_point(self):
        for platform, files in {
            'windows': ['02-install-science.ps1', '06-diagnostics.ps1', '04-remove-science.ps1',
                        '05-remove-micromamba.ps1', 'science-runtime-check.py'],
            'linux': ['01-install-science.sh', '03-remove-science.sh', '04-remove-micromamba.sh',
                      '05-diagnostics.sh', 'science-runtime-check.py'],
        }.items():
            for filename in files:
                source = (ROOT / platform / filename).read_text(encoding='utf-8-sig')
                self.assertNotRegex(source, r'science-camera\.py|07-.*camera|--camera|VideoCapture\([^\n]*CAP_(V4L2|DSHOW)')


if __name__ == '__main__':
    unittest.main()
