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
            root = Path(directory)
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
        with patch.object(camera, 'preview_frames', return_value='PREVIEW_UNAVAILABLE'):
            value, _ = self.capture([(True, FRAME)] * 3, OPTIONS | {'preview': True})
        self.assertEqual((value['status'], value['preview']), ('PASS', 'PREVIEW_UNAVAILABLE'))
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
