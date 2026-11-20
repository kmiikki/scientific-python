"""Exercise the Ubuntu optional-package menu without touching a user environment."""
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
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

    def menu(self, *answers, cuda=False, fresh=False):
        output = []
        reader = iter(answers)
        with patch.object(manager, 'has_nvidia_device', return_value=cuda):
            install = installer.select_optional_packages(lambda _: next(reader), output.append, fresh=fresh)
        return install, '\n'.join(output)

    def test_cpu_saves_exact_backup_and_repeated_selection_is_read_only(self):
        before = self.path.read_bytes()
        install, output = self.menu('1')
        self.assertTrue(install)
        self.assertIn('Configured PyTorch backend: NONE', output)
        self.assertTrue(output.endswith('PyTorch CPU selected.'))
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

    def test_cuda_device_probe_runs_after_selection(self):
        output = []
        with patch.object(manager, 'has_nvidia_device', return_value=True) as probe:
            def choose_cuda(_):
                probe.assert_not_called()
                self.assertFalse(any(line.startswith('NVIDIA CUDA device') for line in output))
                return '2'

            self.assertTrue(installer.select_optional_packages(choose_cuda, output.append, fresh=True))
            probe.assert_called_once_with()
        self.assertTrue(any(line.startswith('NVIDIA CUDA device detected.') for line in output))

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
        self.assertIn('O  Configure optional packages and install/update', result.stdout)
        self.assertIn('Optional package selection requires an interactive terminal', result.stderr)

    def run_install(self, root, answers, runner, *, cuda=False, preflight=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        binary = root / 'bin/micromamba'
        settings = {'driver': '13.2', 'architecture': '12.0', 'runtime_limit': '13.3',
                    'overrides': {}, 'minor_limit': None}
        ask = installer.ask
        with ExitStack() as stack:
            for boundary in (
                redirect_stdout(stdout), redirect_stderr(stderr),
                patch.object(sys.stdin, 'isatty', return_value=True),
                patch.object(stdout, 'isatty', return_value=True),
                patch.object(sys, 'argv', ['science-install.py', 'install']),
                patch.object(Path, 'home', return_value=self.work),
                patch('builtins.input', side_effect=answers),
                patch.object(installer, 'ask', side_effect=lambda prompt, default=None, reader=None:
                             ask(prompt, default, reader or input)),
                patch.object(manager, 'platform_guard'),
                patch.object(installer, 'detect', return_value={'prior': []}),
                patch.object(installer, 'select', return_value=('Existing', root, binary)),
                patch.object(installer, 'ensure_micromamba', return_value=(binary, '2.10.0')),
                patch.object(installer, 'preflight', side_effect=preflight), patch.object(installer, 'summary'),
                patch.object(installer, 'diagnostics'), patch.object(installer, 'recheck_usage', return_value=True),
                patch.object(installer, 'logged_runner', side_effect=runner),
                patch.object(manager, 'using_science', return_value=False),
            ):
                stack.enter_context(boundary)
            probe = stack.enter_context(patch.object(manager, 'has_nvidia_device', return_value=cuda))
            compatibility = stack.enter_context(patch.object(manager, 'cuda_solver_settings', return_value=settings))
            code = installer.main()
        return code, stdout.getvalue(), stderr.getvalue(), probe, compatibility

    def test_fresh_install_choices_agree_with_configuration_and_package_plan_preview(self):
        stale = self.defaults | {'ScientificPackages': self.defaults['ScientificPackages'] + ["pytorch[build='cuda*']"]}
        backup = self.path.with_suffix('.json.backup-timestamp')
        backup.write_text(json.dumps(stale))
        for answer, backend, build, label in [
            ('', 'none', None, 'No PyTorch selected.'),
            ('1', 'cpu', 'cpu_mkl_py314_0', 'PyTorch CPU selected.'),
            ('2', 'cuda', 'cuda129_fixture', 'PyTorch CUDA selected.'),
        ]:
            with self.subTest(backend=backend):
                self.path.unlink(missing_ok=True)
                root = self.work / backend
                support = root / 'share/scientific-python'
                support.mkdir(parents=True)
                snapshot = support / 'science-release.json'
                snapshot.write_bytes(backup.read_bytes())
                records = self.fixture_plan(build) if build else config.read_json(
                    ROOT / 'shared/fixtures/approved-linux-records.json')
                if backend == 'cuda':
                    records += [
                        {'name': 'cuda-version', 'version': '12.9', 'build': 'fixture',
                         'subdir': 'noarch', 'sha256': 'a' * 64},
                        {'name': 'cuda-arch', 'version': '7.5', 'build': 'fixture',
                         'subdir': 'noarch', 'sha256': 'b' * 64},
                    ]
                requested = self.defaults['ScientificPackages'] + ([f"pytorch[build='{backend}*']"] if build else [])
                solved = []

                def runner(argv, **_):
                    self.assertEqual(argv[1], 'create')
                    self.assertIn('--dry-run', argv)
                    self.assertEqual([item for item in argv if str(item).startswith('pytorch')], [f"pytorch[build='{backend}*']"] if build else [])
                    self.assertEqual(config.read_json(self.path)['ScientificPackages'], requested)
                    solved.append(backend)
                    plan = {'success': True, 'actions': {'LINK': records}}
                    return subprocess.CompletedProcess(argv, 0, json.dumps(plan), '')

                # Select the backend, skip the desktop shortcut, then decline package changes.
                code, output, errors, probe, compatibility = self.run_install(
                    root, [answer, 'n', 'n'], runner, cuda=True)
                if backend == 'cuda':
                    probe.assert_called_once_with()
                    compatibility.assert_called_once()
                else:
                    probe.assert_not_called()
                    compatibility.assert_not_called()
                    self.assertNotIn('NVIDIA CUDA device', output)
                self.assertEqual(code, 1)
                self.assertEqual(solved, [backend])
                self.assertIn('0  No PyTorch (default)', output)
                self.assertIn(label, output)
                self.assertIn('not approved', errors)
                plan = config.read_json(root / '.science-update-plan.json')
                torch = [item['build'] for item in plan['changes']['LINK'] if item['name'] == 'pytorch']
                self.assertEqual(torch, [build] if build else [])
                self.assertFalse((root / 'envs/science').exists())
                self.assertEqual(snapshot.read_bytes(), backup.read_bytes())

    def test_fresh_default_clears_saved_cuda_and_keeps_other_requests(self):
        self.assertTrue(self.menu('2', cuda=True)[0])
        value = config.read_json(self.path)
        value['ScientificPackages'].append('pytest')
        self.path.write_text(json.dumps(value))
        original = self.path.read_bytes()
        proceed, output = self.menu('2', '', fresh=True)
        self.assertTrue(proceed)
        self.assertIn('CUDA requires a working NVIDIA driver', output)
        self.assertTrue(output.endswith('No PyTorch selected.'))
        self.assertEqual(config.read_json(self.path)['ScientificPackages'], self.defaults['ScientificPackages'] + ['pytest'])
        self.assertTrue(any(path.read_bytes() == original for path in self.path.parent.glob('science-release.optional-*.json')))

    def test_update_keeps_active_requests_and_recovers_snapshot_only_if_missing(self):
        root = self.work / 'existing'
        (root / 'envs/science').mkdir(parents=True)
        support = root / 'share/scientific-python'
        support.mkdir(parents=True)
        snapshot = support / 'science-release.json'
        snapshot.write_text(json.dumps(self.defaults | {
            'ScientificPackages': self.defaults['ScientificPackages'] + ["pytorch[build='cuda*']"]}))
        self.path.unlink()
        recovered = config.initialize(BUNDLE, root=root)
        self.assertEqual(config.pytorch_backend(recovered['ScientificPackages']), 'cuda')
        self.assertTrue(self.menu('1')[0])
        original = self.path.read_bytes()
        with patch.object(manager, 'owned_science', return_value=True):
            with self.assertRaisesRegex(RuntimeError, 'Reached update'):
                self.run_install(root, ['n'], lambda *_: self.fail('Unexpected solver invocation'),
                                 preflight=RuntimeError('Reached update'))
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(config.pytorch_backend(config.effective(BUNDLE)['ScientificPackages']), 'cpu')

    def test_fresh_solver_cannot_pull_in_unselected_pytorch(self):
        root = self.work / 'fresh'
        root.mkdir()
        plan = {'success': True, 'actions': {'LINK': self.fixture_plan('cuda129_fixture')}}
        runner = lambda argv, **_: subprocess.CompletedProcess(argv, 0, json.dumps(plan), '')
        with redirect_stdout(io.StringIO()), patch.object(manager, 'using_science', return_value=False):
            with self.assertRaisesRegex(manager.InstallError, 'includes PyTorch as a dependency'):
                manager.sync(root, config.effective(BUNDLE), runner=runner, existing=True,
                             reviewer=lambda *_: self.fail('Unexpected package approval'))
        self.assertFalse((root / 'envs/science').exists())

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

    def cuda_runner(self, virtual, solve=None, capabilities='12.0\n', driver=True):
        def runner(argv, env=None, **_):
            if Path(argv[0]).name == 'nvidia-smi':
                if argv[1] == '--query':
                    xml = '<driver_version>595.99.02</driver_version><cuda_version>13.2</cuda_version>'
                    return subprocess.CompletedProcess(argv, 0 if driver else 1, xml, '')
                return subprocess.CompletedProcess(argv, 0, capabilities, '')
            if argv[1] == 'info':
                return subprocess.CompletedProcess(argv, 0, json.dumps({'virtual packages': virtual(env)}), '')
            self.assertIsNotNone(solve, 'Solver must not start')
            return solve(argv, env)
        return runner

    def test_cuda_uses_native_virtual_packages_when_they_match_hardware(self):
        runner = self.cuda_runner(lambda _: ['__cuda=13.2=0', '__cuda_arch=9.0=0'],
                                  capabilities='12.0\n9.0\n')
        with patch.object(manager.shutil, 'which', return_value='/inert/nvidia-smi'):
            settings = manager.cuda_solver_settings('micromamba', self.work, runner, {})
        self.assertEqual(settings['overrides'], {})
        self.assertEqual(settings['architecture'], '9.0')

    def test_cuda_overrides_use_verified_hardware_and_stay_in_subprocesses(self):
        for supports_architecture in (False, True):
            with self.subTest(supports_architecture=supports_architecture):
                seen = []

                def virtual(env):
                    seen.append(dict(env))
                    packages = ['__cuda=' + env.get('CONDA_OVERRIDE_CUDA', '12.9') + '=0']
                    if supports_architecture and 'CONDA_OVERRIDE_CUDA_ARCH' in env:
                        packages.append('__cuda_arch=' + env['CONDA_OVERRIDE_CUDA_ARCH'] + '=0')
                    return packages

                with patch.object(manager.shutil, 'which', return_value='/inert/nvidia-smi'):
                    original = {}
                    settings = manager.cuda_solver_settings('micromamba', self.work, self.cuda_runner(virtual), original)
                self.assertEqual(original, {})
                self.assertEqual(seen, [{}, {'CONDA_OVERRIDE_CUDA': '13.2', 'CONDA_OVERRIDE_CUDA_ARCH': '12.0'}])
                self.assertEqual(settings['driver'], '13.2')
                self.assertEqual(settings['overrides'].get('CONDA_OVERRIDE_CUDA_ARCH'),
                                 '12.0' if supports_architecture else None)

    def test_cuda_rejects_incorrect_architecture_and_missing_driver(self):
        for runner, reason in [
            (self.cuda_runner(lambda _: ['__cuda=13.2=0', '__cuda_arch=12.1=0']), 'disagrees'),
            (self.cuda_runner(lambda env: ['__cuda=13.2=0'] +
                              (['__cuda_arch=12.1=0'] if env else [])), 'different from'),
            (self.cuda_runner(lambda _: [], driver=False), 'could not be verified'),
            (self.cuda_runner(lambda _: []), 'verify the NVIDIA driver'),
            (self.cuda_runner(lambda _: [], capabilities='[Not Supported]'), 'could not be verified'),
        ]:
            with self.subTest(reason=reason), patch.object(manager.shutil, 'which', return_value='/inert/nvidia-smi'):
                with self.assertRaisesRegex(manager.InstallError, reason):
                    manager.cuda_solver_settings('micromamba', self.work, runner, {})

    def test_cuda_architecture_solver_failure_cannot_reach_approval(self):
        self.assertTrue(self.menu('2', cuda=True)[0])
        root = self.work / 'cuda-architecture-fixture'
        root.mkdir()

        def solve(argv, env):
            self.assertIn('--dry-run', argv)
            return subprocess.CompletedProcess(argv, 1, '{"solver_problems": ["nothing provides __cuda_arch"]}', '')

        with patch.object(manager.shutil, 'which', return_value='/inert/nvidia-smi'), redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(manager.InstallError, '__cuda_arch'):
                runner = self.cuda_runner(lambda _: ['__cuda=13.2=0'], solve)
                manager.sync(root, config.effective(BUNDLE), runner=runner, existing=True,
                             reviewer=lambda *_: self.fail('Review should not start'))
        self.assertFalse((root / 'envs/science').exists())

    def test_cuda_compatible_minor_plan_reaches_review_without_modifications(self):
        self.assertTrue(self.menu('2', cuda=True)[0])
        root = self.work / 'cuda-minor'
        root.mkdir()
        attempts = []
        records = self.fixture_plan('cuda134_mkl_py314_fixture') + [
            {'name': 'cuda-version', 'version': '13.5', 'build': 'fixture', 'subdir': 'noarch',
             'sha256': 'a' * 64, 'url': 'https://conda.anaconda.org/conda-forge/noarch/cuda-version-fixture.conda',
             'constrains': ['__cuda >=13']},
            {'name': 'cuda-arch', 'version': '7.5', 'build': 'fixture', 'subdir': 'noarch', 'sha256': 'b' * 64},
        ]

        def solve(argv, env):
            self.assertEqual(env['CONDA_OVERRIDE_CUDA'], '13.2')
            self.assertNotIn('CONDA_OVERRIDE_CUDA_ARCH', env)
            self.assertIn('--dry-run', argv)
            attempts.append(argv[-2])
            if len(attempts) == 1:
                error = '{"solver_problems": ["pytorch requires cuda-version >=13.4,<14"]}'
                return subprocess.CompletedProcess(argv, 1, error, '')
            return subprocess.CompletedProcess(argv, 0, json.dumps({'success': True, 'actions': {'LINK': records}}), '')

        def decline(plan, before, after):
            self.assertTrue(plan['cuda_compatibility']['minor_version_compatibility'])
            self.assertEqual(plan['cuda_compatibility']['runtime'], '13.5')
            return False

        runner = self.cuda_runner(lambda env: ['__cuda=' + env.get('CONDA_OVERRIDE_CUDA', '12.9') + '=0'], solve)
        with patch.object(manager.shutil, 'which', return_value='/inert/nvidia-smi'), redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(manager.InstallError, 'not approved'):
                manager.sync(root, config.effective(BUNDLE), runner=runner, existing=True, reviewer=decline)
        self.assertEqual(attempts, ['cuda-version<13.3', 'cuda-version<14'])
        self.assertFalse((root / 'envs/science').exists())

    def test_cuda_rejects_other_runtime_majors_and_unsupported_gpu(self):
        settings = {'runtime_limit': '13.3', 'minor_limit': '14', 'architecture': '12.0'}
        with self.assertRaisesRegex(manager.InstallError, 'GPU compute capability'):
            manager.assert_cuda_solution({'cuda-arch': {'version': '12.1'}}, settings)
        with self.assertRaisesRegex(manager.InstallError, 'exceeds'):
            manager.assert_cuda_solution({'cuda-arch': {'version': '12.0'}, 'cuda-version': {'version': '14.0'}},
                                         settings)


if __name__ == '__main__':
    unittest.main()
