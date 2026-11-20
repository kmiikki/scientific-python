"""Exercise the Ubuntu removal menu and confirmations with isolated fixtures."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
from shutil import copyfile
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


BUNDLE = Path(__file__).resolve().parents[1] / 'linux'
spec = importlib.util.spec_from_file_location('science_removal_installer', BUNDLE / 'science-install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
manager = installer.m


class ScienceRemoveTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix='science-remove-test-')
        self.addCleanup(work.cleanup)
        self.home = Path(work.name)
        self.root = self.home / 'mamba'
        self.prefix = self.root / 'envs/science'
        self.other = self.root / 'envs/independent'
        self.binary = self.root / 'bin/micromamba'
        self.logs = self.home / '.local/state/scientific-python/logs'
        for path in (self.prefix, self.other, self.binary.parent):
            path.mkdir(parents=True)
        self.config = self.home / 'science-release.json'
        self.config.write_text('saved package configuration')
        (self.prefix / 'keep.txt').write_text('science fixture')
        (self.other / 'keep.txt').write_text('independent environment')
        self.binary.write_text('inert binary')

    def confirm(self, answer):
        output = io.StringIO()

        def reader(prompt):
            print(prompt)
            return answer

        with redirect_stdout(output):
            code = installer.remove_action(self.root, self.binary, self.home, reader)
        return code, output.getvalue().splitlines()

    def test_enter_and_n_return_normally_without_writes(self):
        for answer in ('', 'N'):
            with self.subTest(answer=answer):
                with patch.object(manager, 'remove_science') as remove:
                    code, lines = self.confirm(answer)
                self.assertEqual(code, 0)
                self.assertEqual(lines[-3:], [
                    f'Selected environment: {self.prefix}',
                    'Remove Science environment and its shortcuts? [y/N]: ',
                    'Science removal cancelled.',
                ])
                remove.assert_not_called()
                self.assertFalse(self.logs.exists())
                self.assertFalse((self.root / '.science-installer.lock').exists())
                self.assertEqual(self.config.read_text(), 'saved package configuration')
                self.assertEqual((self.prefix / 'keep.txt').read_text(), 'science fixture')
                self.assertEqual((self.other / 'keep.txt').read_text(), 'independent environment')

    def test_y_passes_the_selected_environment_into_the_existing_removal(self):
        with patch.object(installer, 'recheck_usage', return_value=True) as usage, patch.object(
            manager, 'remove_science', return_value={'status': 'PASS'}
        ) as remove:
            code, lines = self.confirm('Y')
        self.assertEqual(code, 0)
        self.assertIn('Removal result: PASS', lines)
        usage.assert_called_once()
        remove.assert_called_once_with(self.root, home=self.home, mm=self.binary, runner=installer.logged_runner)
        report, = self.logs.glob('*.removal.json')
        self.assertEqual(json.loads(report.read_text())['status'], 'PASS')

    def test_a_removal_error_still_returns_failure_and_is_reported(self):
        with patch.object(installer, 'recheck_usage', return_value=True), patch.object(
            manager, 'remove_science', side_effect=OSError('fixture permission denied')
        ):
            code, lines = self.confirm('y')
        self.assertEqual(code, 1)
        self.assertIn('Removal result: FAIL', lines)
        report, = self.logs.glob('*.removal.json')
        self.assertEqual(json.loads(report.read_text())['reason'], 'fixture permission denied')

    def test_in_use_check_still_blocks_the_removal(self):
        with patch.object(installer, 'recheck_usage', return_value=False), patch.object(
            manager.processes, 'inspect', return_value={'status': 'BLOCKED'}
        ), patch.object(manager, 'remove_science') as remove:
            code, lines = self.confirm('y')
        self.assertEqual(code, 2)
        self.assertIn('Removal result: BLOCKED', lines)
        remove.assert_not_called()

    def test_approval_does_not_bypass_the_ownership_guard(self):
        with patch.object(installer, 'recheck_usage', return_value=True), patch.object(
            manager.safety, 'remove_tree', side_effect=AssertionError('Unexpected mutation')
        ) as remove:
            code, lines = self.confirm('y')
        self.assertEqual(code, 1)
        self.assertIn('Removal result: FAIL', lines)
        self.assertIn('Science ownership is unverified', '\n'.join(lines))
        remove.assert_not_called()


class ScopedRemovalTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix='science-scoped-removal-')
        self.addCleanup(work.cleanup)
        self.home = Path(work.name)
        self.root = self.home / 'micromamba'
        self.prefix = self.root / 'envs/science'
        self.other = self.root / 'envs/analysis'
        self.cache = self.root / 'pkgs'
        self.binary = self.root / 'bin/micromamba'
        self.registry = self.home / '.conda/environments.txt'
        self.bashrc = self.home / '.bashrc'
        self.configuration = self.root / 'science-release.json'
        self.active_configuration = self.home / '.config/scientific-python/science-release.json'
        self.launcher = self.binary.with_name('science-spyder')
        for directory in (self.prefix / 'conda-meta', self.other / 'lib/site-packages',
                          self.cache, self.binary.parent, self.registry.parent, self.active_configuration.parent):
            directory.mkdir(parents=True)
        self.other_payload = self.other / 'lib/site-packages/data.txt'
        self.cache_payload = self.cache / 'shared-payload'
        self.other_payload.write_bytes(b'other environment data')
        self.cache_payload.write_bytes(b'shared package data')
        os.link(self.cache_payload, self.prefix / 'hardlinked-package-file')
        (self.prefix / 'independent-link').symlink_to(self.other, target_is_directory=True)
        self.binary.write_bytes(b'inert micromamba fixture')
        self.binary.chmod(0o755)
        self.configuration.write_bytes(b'saved package requests')
        self.active_configuration.write_bytes(b'active package requests')
        self.bashrc.write_bytes(b'activation settings')
        self.kept_registry = str(self.other).encode() + b'\r\n'
        self.registry.write_bytes(self.kept_registry + str(self.prefix).encode() + b'\n')
        self.launcher.write_text(
            '# Scientific Python managed Spyder launcher\n'
            '# Scientific-Python-Root-Id: ' + manager.fingerprint(str(self.root)) + '\n')
        self.receipt = self.root / '.science-env-owner.json'
        info = self.prefix.stat()
        manager.write_json(self.receipt, {
            'managed_by': manager.safety.PRODUCT, 'scope': 'science-environment',
            'root': str(self.root), 'prefix': str(self.prefix), 'phase': 'installed',
            'prefix_identity': [info.st_dev, info.st_ino], 'micromamba_exe': str(self.binary),
        })
        manager.write_json(self.prefix / '.science-owner.json',
                           {'managed_by': manager.safety.PRODUCT, 'root': str(self.root)})

    def run_removal(self, *, busy=manager.using_science):
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, '2.10.0\n', ''))
        with redirect_stdout(io.StringIO()):
            return manager.remove_science(self.root, self.home, runner=runner, busy=busy, mm=self.binary)

    def test_scoped_removal_preserves_shared_files_and_can_repeat(self):
        preserved = (self.other_payload, self.cache_payload, self.binary,
                     self.configuration, self.active_configuration, self.bashrc)
        contents = {path: path.read_bytes() for path in preserved}
        with patch.object(manager.lifecycle, 'tree_metadata', side_effect=AssertionError('Unexpected tree walk')):
            report = self.run_removal(busy=lambda _: False)
            again = self.run_removal(busy=lambda _: False)
        for result in (report, again):
            self.assertEqual(result['status'], 'PASS')
            self.assertEqual(result['other_environments'], 'PRESERVED')
            self.assertEqual(result['cache_and_user_files'], 'PRESERVED')
            self.assertEqual(result['registry_other_lines'], 'PRESERVED')
        for path in (self.prefix, self.launcher, self.receipt):
            self.assertFalse(path.exists())
        self.assertEqual(self.registry.read_bytes(), self.kept_registry)
        self.assertEqual({path: path.read_bytes() for path in preserved}, contents)
        self.assertEqual(self.cache_payload.stat().st_nlink, 1)

    def test_boundary_comparison_detects_changed_environment_cache_and_configuration(self):
        before = manager.lifecycle.preservation(self.root, self.home, self.binary)
        self.other.rename(self.other.with_name('relocated'))
        self.other.mkdir()
        self.cache_payload.unlink()
        self.configuration.write_bytes(b'different requests')
        self.bashrc.write_bytes(b'different profile')
        after = manager.lifecycle.preservation(self.root, self.home, self.binary)
        for key in ('others', 'cache', 'root_entries', 'bashrc'):
            self.assertNotEqual(before[key], after[key], key)
        self.assertEqual(before['micromamba_sha256'], after['micromamba_sha256'])

    def test_replaced_prefix_cannot_be_removed(self):
        self.prefix.rename(self.prefix.with_name('relocated-science'))
        self.prefix.mkdir()
        with self.assertRaisesRegex(manager.InstallError, 'identity differs'):
            self.run_removal(busy=lambda _: False)
        self.assertTrue(self.prefix.is_dir())
        self.assertTrue(self.launcher.exists())

    def test_redirected_prefix_cannot_be_removed(self):
        self.prefix.rename(self.prefix.with_name('relocated-science'))
        self.prefix.symlink_to(self.other, target_is_directory=True)
        with self.assertRaisesRegex(manager.InstallError, 'symlinked'):
            self.run_removal(busy=lambda _: False)
        self.assertTrue(self.prefix.is_symlink())
        self.assertTrue(self.other_payload.exists())

    def test_nested_environment_cannot_be_removed(self):
        nested = self.prefix / 'research-env'
        nested.mkdir()
        (nested / 'pyvenv.cfg').touch()
        with self.assertRaisesRegex(manager.InstallError, 'Nested Python/Conda environment'):
            self.run_removal(busy=lambda _: False)
        self.assertTrue((nested / 'pyvenv.cfg').exists())

    def test_mount_added_after_preflight_blocks_deletion(self):
        mounted = self.prefix / 'mount'
        mounted.mkdir()
        with patch.object(manager.safety, 'mount_points', side_effect=[[], [mounted]]):
            with self.assertRaisesRegex(manager.InstallError, 'Mounted directory inside removal target'):
                self.run_removal(busy=lambda _: False)
        self.assertTrue(mounted.is_dir())
        self.assertTrue(self.launcher.exists())
        self.assertIn(str(self.prefix).encode(), self.registry.read_bytes())

    def test_active_science_shell_blocks_removal(self):
        with patch.dict(os.environ, {'CONDA_PREFIX': str(self.prefix)}):
            with self.assertRaises(manager.UsageBlocked) as blocked:
                self.run_removal()
        self.assertIn('current_shell', {item['kind'] for item in blocked.exception.report['blockers']})
        self.assertTrue(self.prefix.is_dir())
        self.assertTrue(self.launcher.exists())


class RemovalMenuTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix='science-removal-menu-')
        self.addCleanup(work.cleanup)
        self.home = Path(work.name)
        self.root = self.home / 'micromamba'
        self.binary = self.root / 'bin/micromamba'
        for name in ('bin', 'envs', 'pkgs'):
            (self.root / name).mkdir(parents=True)
        self.binary.write_text('inert executable')
        self.cache = self.root / 'pkgs/keep.txt'
        self.launcher = self.root / 'start-spyder.sh'
        self.cache.write_text('package cache')
        self.launcher.write_text('launcher')
        info = self.root.stat()
        self.receipt = self.root / '.science-root-owner.json'
        manager.write_json(self.receipt, {
            'managed_by': 'scientific-python-ubuntu', 'scope': 'micromamba-binary',
            'root': str(self.root), 'executable': str(self.binary),
            'sha256': manager.safety.file_plan(self.binary)['sha256'],
            'created_root_identity': [info.st_dev, info.st_ino],
        })
        self.state = self.root / '.scientific-python-installer-state'
        self.state.write_text('managed_by=scientific-python-ubuntu\nroot_owned=true\n')

    def executable_action(self, answer):
        output = io.StringIO()

        def reader(prompt):
            print(prompt)
            return answer

        with redirect_stdout(output), patch.object(manager, 'using_science', return_value=False), patch.object(
            manager.safety, 'root_inventory', return_value={'paths': [], 'original': None}
        ), patch.object(manager.safety, 'check_registry'):
            code = installer.remove_micromamba_action(self.root, self.home, reader)
        return code, output.getvalue().splitlines()

    def test_labels_and_action_numbers_route_in_the_real_menu(self):
        copyfile(BUNDLE / '00-menu.sh', self.home / '00-menu.sh')
        (self.home / 'science-common.sh').write_text('MANAGER="$SCRIPT_DIR/stub-manager.py"\n')
        (self.home / 'stub-manager.py').write_text('print("10.20.300")\n')
        (self.home / '03-remove-science.sh').write_text("printf 'routed science\\n'\n")
        (self.home / '04-remove-micromamba.sh').write_text("printf 'routed executable\\n'\n")
        (self.home / 'science-install.py').write_text('import sys\nprint("routed", sys.argv[1])\n')
        result = subprocess.run(['bash', self.home / '00-menu.sh'], input='3\n4\n5\nq\n',
                                text=True, capture_output=True, check=True, timeout=10)
        lines = result.stdout.splitlines()
        header = 'Scientific Python 10.20.300 (Ubuntu LTS)'
        starts = [i for i, line in enumerate(lines) if line == header]
        self.assertEqual(len(starts), 4)
        for start in starts:
            self.assertEqual(lines[start:start + 4],
                             [header, '=' * len(header), '', '1  Install/update Scientific Python'])
        for line in ('3  Remove Science environment', '4  Remove Micromamba installed by Scientific Python',
                     '5  Total Remove – delete selected Micromamba directory and all contents',
                     'routed science', 'routed executable', 'routed remove-total'):
            self.assertIn(line, lines)
        self.assertEqual(result.stderr, '')

    def test_executable_removal_enter_and_n_cancel_after_showing_both_paths(self):
        for answer in ('', 'N'):
            with self.subTest(answer=answer):
                code, lines = self.executable_action(answer)
                self.assertEqual(code, 0)
                self.assertEqual(lines, [
                    'Micromamba executable:', str(self.binary),
                    'Micromamba directory:', str(self.root),
                    'This Micromamba may also manage other Python environments.',
                    'All environments and package caches will be preserved.',
                    'Remove this Micromamba executable? [y/N]: ',
                    'Micromamba removal cancelled.',
                ])
                self.assertTrue(self.binary.is_file())
                self.assertFalse((self.root / '.science-installer.lock').exists())

    def test_executable_approval_unlinks_only_the_fixture_binary(self):
        outside = self.home / 'other-root/micromamba'
        outside.parent.mkdir()
        outside.write_bytes(self.binary.read_bytes())
        code, lines = self.executable_action('Y')
        self.assertEqual(code, 0)
        self.assertIn('The Micromamba executable was removed.', lines)
        self.assertFalse(self.binary.exists())
        self.assertEqual(outside.read_text(), 'inert executable')
        self.assertEqual(self.cache.read_text(), 'package cache')
        self.assertEqual(self.launcher.read_text(), 'launcher')
        self.assertTrue(self.receipt.is_file())

    def test_unowned_and_changed_executables_are_refused_before_confirmation(self):
        reader = Mock(return_value='y')
        with patch.object(manager.safety, 'unlink_file') as unlink:
            self.state.write_text('managed_by=scientific-python-ubuntu\nroot_owned=false\n')
            with self.assertRaisesRegex(manager.InstallError, 'Existing Micromamba'):
                installer.remove_micromamba_action(self.root, self.home, reader)
            self.state.write_text('managed_by=scientific-python-ubuntu\nroot_owned=true\n')
            self.binary.write_text('different executable')
            with self.assertRaisesRegex(manager.InstallError, 'changed outside'):
                installer.remove_micromamba_action(self.root, self.home, reader)
        reader.assert_not_called()
        unlink.assert_not_called()

    def test_replaced_target_during_confirmation_is_refused_even_with_the_same_bytes(self):
        def reader(prompt):
            replacement = self.binary.with_suffix('.replacement')
            replacement.write_bytes(self.binary.read_bytes())
            replacement.replace(self.binary)
            return 'Y'

        with redirect_stdout(io.StringIO()), patch.object(manager, 'using_science', return_value=False), patch.object(
            manager.safety, 'root_inventory', return_value=None
        ), patch.object(manager.safety, 'unlink_file') as unlink:
            with self.assertRaisesRegex(manager.InstallError, 'changed during confirmation'):
                installer.remove_micromamba_action(self.root, self.home, reader)
        unlink.assert_not_called()

    def test_total_remove_preview_is_the_same_for_managed_and_external_directories(self):
        for directory, approve in ((self.root, False), (self.home / 'external root', True)):
            with self.subTest(directory=directory):
                inventory = {'selected': str(directory)}
                plan = {'registry': None}
                output = io.StringIO()
                with redirect_stdout(output), patch.object(manager, 'total_removal_plan', return_value=plan) as get_plan, patch.object(
                    installer, 'confirm_total_removal', return_value=approve
                ) as confirm, patch.object(manager, 'apply_total_removal', return_value=[str(directory)]) as apply:
                    self.assertEqual(installer.total_remove_action(directory, self.home, inventory, False), 0)
                self.assertEqual(output.getvalue().splitlines()[:10], [
                    'Selected Micromamba directory:', str(directory), '',
                    'This will permanently delete:', '',
                    '- All environments in this directory', '- Package caches',
                    '- All other files, including user files', '',
                    'The selected directory and its entire contents will be deleted.',
                ])
                get_plan.assert_called_once_with(directory, self.home, inventory)
                confirm.assert_called_once_with(directory, False)
                if approve:
                    self.assertEqual(apply.call_args.args[:3], (directory, self.home, plan))
                else:
                    apply.assert_not_called()


if __name__ == '__main__':
    unittest.main()
