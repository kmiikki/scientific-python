"""Run the real approved installer path against an offline disposable fixture."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

BUNDLE = Path(__file__).resolve().parents[1] / 'linux'
spec = importlib.util.spec_from_file_location('science_install_progress', BUNDLE / 'science-install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
manager = installer.m
PROGRESS = re.compile(r'^\[6/9\] Installing packages +RUNNING +Elapsed: (\d+):(\d\d)  (.+)$', re.MULTILINE)

# The substitute resolves only prewritten records. Its sole write target is
# the fixture's Science prefix, and even the online solve is simulated.
NATIVE = """
import json
import sys
import time
from pathlib import Path

exe = Path(__file__).resolve()
root = exe.parent.parent
fixture = json.loads(exe.with_suffix('.json').read_text())
args = sys.argv[1:]
target = Path(args[args.index('-p') + 1])
assert Path(args[args.index('-r') + 1]) == root
prefix = root / 'envs/science'
assert target == prefix or (target.name.startswith('download-prefix-')
                            and target.is_relative_to(root / '.science-transactions'))
commit = '--offline' in args and '--download-only' not in args and '--dry-run' not in args and '-y' in args
plan = {'success': True, 'prefix': str(target), 'actions': {'LINK': fixture['records'], 'UNLINK': []}}
sys.stdout.write(json.dumps(plan))  # remains buffered until this process exits
if commit:
    assert target == prefix
    time.sleep(fixture['native_delay'])
    if fixture['exit_code']:
        sys.stderr.write('fixture native failure')
        sys.exit(fixture['exit_code'])
    for record in fixture['records']:
        (prefix / 'conda-meta' / (record['name'] + '.json')).write_text(json.dumps(record))
"""


class Fixture:
    def __init__(self, work, native_delay=0, exit_code=0):
        self.home = work / 'home'
        self.root = self.home / 'micromamba'
        self.binary = self.root / 'bin/micromamba'
        cache = self.root / 'pkgs'
        self.binary.parent.mkdir(parents=True)
        cache.mkdir()
        self.config = manager.science_config.effective(BUNDLE, path=work / 'absent.json')
        foundations = {
            'python': (self.config['Python'] + '.0', 'h0'),
            'python_abi': (self.config['Python'], 'h0_cp314'),
            'spyder': (self.config['Spyder'], 'h0'),
            'opencv': (self.config['OpenCV'], 'qt6_h0'),
            'ffmpeg': (self.config['FFmpeg'], 'gpl_h0'),
            'apache-arrow-proc': ('1.0', 'cpu'),
        }
        self.config['ScientificPackages'] = [
            request for request in self.config['ScientificPackages'] if manager.spec_name(request) in foundations
        ]
        records = []
        for name, (version, build) in foundations.items():
            filename = f'{name}-{version}-{build}.conda'
            data = f'fake archive for {name}'.encode()
            (cache / filename).write_bytes(data)
            records.append(dict(name=name, version=version, build=build, subdir='linux-64', fn=filename,
                                sha256=hashlib.sha256(data).hexdigest(), size=len(data),
                                url='https://example.invalid/linux-64/' + filename))
        self.binary.with_suffix('.json').write_text(json.dumps(dict(records=records, native_delay=native_delay,
                                                                    exit_code=exit_code)))
        self.binary.write_text('#!' + sys.executable + '\n' + NATIVE)
        self.binary.chmod(0o700)

    def install(self, **options):
        def no_network(*_):
            raise AssertionError('A disposable fixture must never fetch remote archives')

        return installer.install_packages(self.root, self.config, home=self.home, mm=self.binary,
                                          existing=True, fetch=no_network, **options)


def heartbeats(output):
    return [(int(minutes) * 60 + int(seconds), activity) for minutes, seconds, activity in PROGRESS.findall(output)]


def successful_progress(interval, delay, *, terminal=None):
    with tempfile.TemporaryDirectory(prefix='science-package-progress-', dir='/tmp') as temp:
        work = Path(temp)
        fixture = Fixture(work, native_delay=delay)
        restore = manager.restore_approved_metadata

        def slow_verification(*args):
            time.sleep(delay)
            return restore(*args)

        with (work / 'progress.log').open('w+') as log:
            with contextlib.redirect_stdout(installer.Tee(terminal or io.StringIO(), log)):
                with patch.object(manager, 'restore_approved_metadata', side_effect=slow_verification):
                    changed = fixture.install(reviewer=lambda *_: True, interval=interval)
                log.seek(0)
                output = log.read()
                time.sleep(interval + .1)
                log.seek(0)
                assert log.read() == output, 'Progress continued after installation returned'
        assert changed and (fixture.root / 'science-packages.json').is_file()
        assert re.search(r'\[6/9\] Installing packages +PASS', output)
        return heartbeats(output), output


class PackageProgressTests(unittest.TestCase):
    def test_production_installation_progress_during_native_and_python_work(self):
        beats, _ = successful_progress(.1, 2.2)
        self.assertEqual(beats[0], (0, 'Python: preparing approved transaction'))
        seconds = [second for second, _ in beats]
        self.assertEqual(seconds, sorted(set(seconds)))
        self.assertTrue(any(activity == 'Micromamba: applying approved transaction' for _, activity in beats))
        self.assertTrue(any(activity == 'Python: verifying installed packages and restoring metadata' for _, activity in beats))

    def test_declined_approval_has_no_package_heartbeat(self):
        with tempfile.TemporaryDirectory(prefix='science-progress-decline-', dir='/tmp') as directory:
            fixture = Fixture(Path(directory))
            with contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaisesRegex(manager.InstallError, 'not approved'):
                    fixture.install(reviewer=lambda *_: False, interval=.1)
            self.assertEqual(heartbeats(output.getvalue()), [])
            self.assertFalse((fixture.root / 'envs/science').exists())

    def test_errors_propagate_and_stop_the_heartbeat(self):
        for native_error in (True, False):
            with self.subTest(native_error=native_error):
                with tempfile.TemporaryDirectory(prefix='science-progress-error-', dir='/tmp') as directory:
                    fixture = Fixture(Path(directory), exit_code=17 if native_error else 0)
                    with contextlib.redirect_stdout(io.StringIO()) as output:
                        with patch.object(manager, 'restore_approved_metadata', side_effect=ValueError('fixture verification error')):
                            expected, message = ((manager.InstallError, r'failed \(exit 17\)') if native_error
                                                 else (ValueError, 'fixture verification error'))
                            with self.assertRaisesRegex(expected, message):
                                fixture.install(reviewer=lambda *_: True, interval=.03)
                        self.assertGreater(len(heartbeats(output.getvalue())), 0)
                        self.assertFalse(any(thread.name == 'science-package-progress'
                                             for thread in installer.threading.enumerate()))
                        captured = output.getvalue()
                        time.sleep(.1)
                        self.assertEqual(captured, output.getvalue())


class InstallationUiTests(unittest.TestCase):
    def test_install_and_validation_show_the_preview_once_and_log_it(self):
        for action, boundary in (('install', 'ensure_micromamba'), ('validate', 'check_micromamba')):
            with self.subTest(action=action), tempfile.TemporaryDirectory(prefix='science-install-ui-') as directory:
                work = Path(directory)
                root = work / 'micromamba'
                root.mkdir()
                config = manager.science_config.effective(BUNDLE, path=work / 'absent.json')
                config['InstallerVersion'] = '10.20.300'

                def stop_at_validation(*args):
                    print('Fixture reached Micromamba validation.')
                    raise manager.InstallError('Fixture stops before native execution.')

                with contextlib.ExitStack() as stack:
                    output = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                    for mock in (
                        patch.dict(os.environ, {'XDG_CONFIG_HOME': str(work / 'config')}),
                        patch.object(sys, 'argv', ['science-install.py', action]),
                        patch.object(Path, 'home', return_value=work),
                        patch.object(manager, 'platform_guard'),
                        patch.object(manager, 'release', return_value=config),
                        patch.object(installer, 'detect', return_value={'prior': []}),
                        patch.object(installer, 'select', return_value=('Existing', root, root / 'bin/micromamba')),
                        patch.object(installer, 'ask', return_value='n'),
                        patch.object(installer, 'diagnostics'),
                        patch.object(installer, boundary, side_effect=stop_at_validation),
                    ):
                        stack.enter_context(mock)
                    self.assertEqual(installer.main(), 1)

                log, = (work / '.local/state/scientific-python/logs').glob('*.log')
                for text in (output.getvalue(), log.read_text()):
                    self.assertEqual(text.count('Current                  Target'), 1)
                    self.assertLess(text.index('Current                  Target'),
                                    text.index('Fixture reached Micromamba validation.'))
                    self.assertIn('The exact resolved target versions will be shown before approval.', text)
                    heading = 'Scientific Python 10.20.300 (Ubuntu LTS)'
                    self.assertEqual(text.count(heading + '\n' + '=' * len(heading) + '\n\n'), 2)
                self.assertFalse((root / 'envs/science').exists())


def native_acceptance():
    print('Isolated progress test. Micromamba and package data are simulated.', flush=True)
    beats, output = successful_progress(5, 12, terminal=sys.stdout)
    seconds = [second for second, _ in beats]
    assert beats[0] == (0, 'Python: preparing approved transaction')
    assert seconds == sorted(set(seconds)), 'Elapsed timestamps repeated or went backwards'
    assert all(4 <= stop - start <= 6 for start, stop in zip(seconds, seconds[1:])), 'Unexpected heartbeat interval'
    for expected in ('Micromamba: applying approved transaction',
                     'Python: verifying installed packages and restoring metadata'):
        assert sum(activity == expected for _, activity in beats) >= 2, 'Missing live progress for ' + expected
    assert 'ACTIVE' not in output
    print('PASS: buffered process, Python verification, five-second progress and clean shutdown.', flush=True)


if __name__ == '__main__':
    if sys.argv[1:] == ['--native']:
        native_acceptance()
    else:
        unittest.main()
