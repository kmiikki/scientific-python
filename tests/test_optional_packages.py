"""Exercise the Ubuntu optional-package menu without touching a user environment."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'linux'
spec = importlib.util.spec_from_file_location('optional_package_installer', BUNDLE / 'science-install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
manager = installer.m
config = manager.science_config


class OptionalPackageTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix='science-optional-tests-')
        self.addCleanup(workspace.cleanup)
        self.work = Path(workspace.name)
        self.env = patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.work / 'config')})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.path = config.active_path()
        self.defaults = config.initialize(BUNDLE)

    def menu(self, *answers, cuda=False):
        output = []
        reader = iter(answers)
        with patch.object(manager, 'has_nvidia_device', return_value=cuda):
            install = installer.select_optional_packages(lambda _: next(reader), output.append)
        return install, '\n'.join(output)

    def test_cpu_saves_exact_backup_and_repeated_selection_is_read_only(self):
        before = self.path.read_bytes()
        install, output = self.menu('1')
        self.assertTrue(install)
        self.assertIn('Configured PyTorch backend: NONE', output)
        self.assertIn('Configured PyTorch backend: CPU', output)
        self.assertEqual(config.read_json(self.path)['ScientificPackages'],
                         self.defaults['ScientificPackages'] + ["pytorch[build='cpu*']"])
        backup, = self.path.parent.glob('science-release.optional-*.json')
        self.assertEqual(backup.read_bytes(), before)
        mtime = self.path.stat().st_mtime_ns
        self.assertTrue(self.menu('1')[0])
        self.assertEqual(self.path.stat().st_mtime_ns, mtime)
        self.assertEqual(list(self.path.parent.glob('science-release.optional-*.json')), [backup])

    def test_cuda_switch_preserves_pytorch_version_channel_and_other_requests(self):
        value = self.defaults
        value['Channels'].append('my-lab')
        value['ScientificPackages'] += ['my-lab::package=1', 'conda-forge::pytorch>=2.13,<=2.14', 'torchvision']
        self.path.write_text(json.dumps(value))
        self.assertTrue(self.menu('1')[0])
        self.assertTrue(self.menu('2', cuda=True)[0])
        after = config.read_json(self.path)
        self.assertEqual(after['Channels'], value['Channels'])
        self.assertEqual(after['ScientificPackages'], value['ScientificPackages'][:-2] +
                         ["conda-forge::pytorch>=2.13,<=2.14[build='cuda*']", 'torchvision'])

    def test_back_unavailable_cuda_and_declined_removal_keep_bytes(self):
        self.assertTrue(self.menu('1')[0])
        before = self.path.read_bytes()
        self.assertFalse(self.menu('r', '')[0])
        install, output = self.menu('2', 'q')
        self.assertFalse(install)
        self.assertIn('CUDA requires a working NVIDIA driver', output)
        self.assertEqual(self.path.read_bytes(), before)

    def test_removal_preserves_other_requests_and_does_not_start_install(self):
        value = self.defaults
        value['ScientificPackages'] += ["pytorch[version='>=2.13',build='cpu*']", 'torchvision=1']
        self.path.write_text(json.dumps(value))
        self.assertFalse(self.menu('r', 'yes')[0])
        self.assertEqual(config.read_json(self.path)['ScientificPackages'], value['ScientificPackages'][:-2] + ['torchvision=1'])

    def test_explicit_build_conflict_is_not_silently_replaced(self):
        self.defaults['ScientificPackages'] += ["pytorch[version='2.13.0',build='cpu_mkl_py314_0']"]
        self.path.write_text(json.dumps(self.defaults))
        original = self.path.read_bytes()
        with self.assertRaisesRegex(config.ConfigError, 'explicit build constraint'):
            self.menu('2', cuda=True)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(list(self.path.parent.glob('science-release.optional-*.json')))

    def test_configuration_changes_during_prompt_are_preserved(self):
        def edit_then_choose(_):
            self.path.write_bytes(self.path.read_bytes() + b'\n')
            return '1'
        with patch.object(manager, 'has_nvidia_device', return_value=False):
            with self.assertRaisesRegex(config.ConfigError, 'changed during review'):
                installer.select_optional_packages(edit_then_choose, lambda _: None)
        self.assertEqual(config.read_json(self.path), self.defaults)

    def test_main_menu_routes_to_optional_action_and_rejects_redirected_input(self):
        result = subprocess.run(['bash', str(BUNDLE / '00-menu.sh')], input='O\nQ\n',
                                capture_output=True, text=True, check=True)
        self.assertIn('O  Optional packages', result.stdout)
        self.assertIn('Optional package selection requires an interactive terminal', result.stderr)

    def fixture_plan(self, build):
        packages = config.read_json(ROOT / 'shared/fixtures/approved-linux-records.json')
        packages.append({'name': 'pytorch', 'version': '2.13.0', 'build': build,
                         'subdir': 'linux-64', 'sha256': '1' * 64, 'size': 0})
        return packages

    def test_normal_solver_checks_build_and_honors_declined_cpu_transaction(self):
        self.assertTrue(self.menu('1')[0])
        effective = config.effective(BUNDLE)
        root = self.work / 'fixture-root'
        root.mkdir()
        argv_history = []
        reviewed = []
        records = self.fixture_plan('cpu_mkl_py314_0')
        plan = {'success': True, 'actions': {'LINK': records}}

        def runner(argv, **_):
            argv_history.append(argv)
            self.assertIn('--dry-run', argv)
            self.assertIn("pytorch[build='cpu*']", argv)
            return subprocess.CompletedProcess(argv, 0, json.dumps(plan), '')

        def decline(proposed, before, after):
            reviewed.append((proposed, before))
            self.assertEqual(after['pytorch']['build'], 'cpu_mkl_py314_0')
            return False

        with redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(manager.InstallError, 'not approved'):
                manager.sync(root, effective, runner=runner, existing=True, reviewer=decline)
        self.assertEqual(len(argv_history), 1)
        self.assertEqual(len(reviewed), 1)
        self.assertFalse((root / 'envs/science').exists())

        altered = {'success': True, 'actions': {'LINK': self.fixture_plan('cuda129_test')}}
        with self.assertRaisesRegex(manager.InstallError, 'requested PyTorch backend'):
            manager.check_plan(altered, {}, effective)

    def test_unchanged_cpu_plan_never_requests_approval_or_commits_packages(self):
        self.assertTrue(self.menu('1')[0])
        root = self.work / 'current-root'
        prefix = root / 'envs/science'
        meta = prefix / 'conda-meta'
        meta.mkdir(parents=True)
        info = prefix.stat()
        manager.write_json(root / '.science-env-owner.json', {
            'managed_by': 'scientific-python-ubuntu', 'scope': 'science-environment',
            'root': str(root), 'prefix': str(prefix), 'micromamba_exe': str(root / 'bin/micromamba'),
            'phase': 'installed', 'prefix_identity': [info.st_dev, info.st_ino],
        })
        manager.write_json(prefix / '.science-owner.json',
                           {'managed_by': 'scientific-python-ubuntu', 'root': str(root)})
        history = meta / 'history'
        history.write_text("# update specs: ['pytorch']\n")
        for record in self.fixture_plan('cpu_mkl_py314_0'):
            manager.write_json(meta / (record['name'] + '.json'), record)
        snapshot = {path.name: path.read_bytes() for path in meta.iterdir()}

        def runner(argv, **_):
            self.assertIn('--dry-run', argv)
            self.assertEqual(argv[1], 'update')
            return subprocess.CompletedProcess(argv, 0, '{"success": true}', '')

        with redirect_stdout(io.StringIO()):
            self.assertFalse(manager.sync(root, config.effective(BUNDLE), runner=runner, existing=True,
                                          reviewer=lambda *_: self.fail('No-op plan must not request approval')))
        self.assertEqual({path.name: path.read_bytes() for path in meta.iterdir()}, snapshot)

    def test_cuda_without_virtual_driver_stops_before_solver_and_approval(self):
        self.assertTrue(self.menu('2', cuda=True)[0])
        root = self.work / 'cuda-fixture'
        root.mkdir()
        def runner(argv, **_):
            self.assertEqual(argv[1], 'info')
            return subprocess.CompletedProcess(argv, 0, '{"virtual packages": ["__linux=0=0"]}', '')
        with patch.object(manager, 'has_nvidia_device', return_value=True):
            with self.assertRaisesRegex(manager.InstallError, 'did not detect a compatible CUDA driver'):
                manager.sync(root, config.effective(BUNDLE), runner=runner, existing=True,
                             reviewer=lambda *_: self.fail('Review should not start'))
        self.assertFalse((root / 'envs/science').exists())

    def test_cuda_architecture_solver_failure_cannot_reach_approval(self):
        self.assertTrue(self.menu('2', cuda=True)[0])
        root = self.work / 'cuda-architecture-fixture'
        root.mkdir()

        def runner(argv, **_):
            if argv[1] == 'info':
                return subprocess.CompletedProcess(argv, 0, '{"virtual packages": ["__cuda=12.9=0"]}', '')
            self.assertIn('--dry-run', argv)
            return subprocess.CompletedProcess(argv, 1, '{"solver_problems": ["nothing provides __cuda_arch"]}', '')

        with patch.object(manager, 'has_nvidia_device', return_value=True), redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(manager.InstallError, 'GPU architecture dependency'):
                manager.sync(root, config.effective(BUNDLE), runner=runner, existing=True,
                             reviewer=lambda *_: self.fail('Review should not start'))
        self.assertFalse((root / 'envs/science').exists())


if __name__ == '__main__':
    unittest.main()
