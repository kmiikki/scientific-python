"""Policy regressions using test directories and a Python child, never Micromamba."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('science_install_migration', ROOT / 'linux/science-install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
m = installer.m


class TestCandidate(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name).resolve()
        self.root = self.home / 'micromamba'
        self.prefix = self.root / 'envs/science'
        self.meta = self.prefix / 'conda-meta'
        self.meta.mkdir(parents=True)
        self.state = self.root / '.scientific-python-installer-state'
        self.receipt = self.root / '.science-env-owner.json'

    def write_v3(self):
        state = dict(managed_by=m.safety.PRODUCT, installer_version='ubuntu-lts-v3', micromamba_version='2.8.1',
                     python_spec='3.14', spyder_spec='6.1.7', layout='home', root=str(self.root), science=str(self.prefix))
        self.state.write_bytes(''.join(f'{key}={value}\n' for key, value in state.items()).encode())
        argv = [str(self.root/'bin/micromamba'), 'create', '-y', '-n', 'science', '--override-channels', '-c', 'conda-forge', *m.LEGACY_V3_SPECS]
        (self.meta/'history').write_text('# cmd: ' + shlex.join(argv) + '\n# update specs: ' + repr(list(m.LEGACY_V3_SPECS)) + '\n')
        for request in m.LEGACY_V3_SPECS:
            name = request.split('=')[0]
            version = {'python': '3.14.0', 'spyder': '6.1.7'}.get(name, '1.0.0')
            build = 'cpu' if name == 'apache-arrow-proc' else 'h0_0'
            item = dict(name=name, version=version, build=build, url=f'https://conda.anaconda.org/conda-forge/linux-64/{name}.conda')
            (self.meta/f'{name}-{version}-{build}.json').write_text(json.dumps(item))
        launcher = self.root/'bin/science-spyder'
        launcher.parent.mkdir(); launcher.write_bytes(b'test archived launcher bytes')
        return launcher

    @contextlib.contextmanager
    def evidence_io(self, launcher):
        with patch.object(m, 'LEGACY_V3_LAUNCHER', hashlib.sha256(launcher.read_bytes()).hexdigest()):
            if os.name == 'posix':
                yield
            else:
                # Windows tests policy; Ubuntu additionally tests POSIX descriptors/ownership.
                with patch.object(m, 'check_legacy_directory'), patch.object(m, 'ownership_file', side_effect=lambda path, **kw: path.read_bytes()):
                    yield

    def test_legacy_evidence_is_read_only_and_exact(self):
        launcher = self.write_v3()
        with self.evidence_io(launcher):
            proof = m.migration_evidence(self.root, self.home)
            self.assertEqual(proof['format'], 'ubuntu-lts-v3')
            self.assertFalse(self.receipt.exists())
            (self.meta/'history').write_text('# cmd: something-else\n')
            with self.assertRaisesRegex(m.InstallError, 'archived V3 create/install command'):
                m.migration_evidence(self.root, self.home)

    def test_conflicting_marker_or_provenance_blocks(self):
        launcher = self.write_v3()
        with self.evidence_io(launcher):
            marker = self.prefix/'.science-owner.json'
            marker.write_text('{"managed_by":"other"}')
            with self.assertRaisesRegex(m.InstallError, 'conflicting ownership'):
                m.migration_evidence(self.root, self.home)
            marker.unlink()
            path = self.meta/'spyder-6.1.7-h0_0.json'
            record = json.loads(path.read_text()); record['url'] = 'https://example.invalid/spyder.conda'
            path.write_text(json.dumps(record))
            with self.assertRaisesRegex(m.InstallError, 'provenance.*spyder'):
                m.migration_evidence(self.root, self.home)
            self.assertFalse(self.receipt.exists())

    @unittest.skipUnless(os.name == 'posix', 'POSIX descriptor and link operations required')
    def test_approved_receipt_does_not_grant_deletion(self):
        launcher = self.write_v3()
        with self.evidence_io(launcher), patch.object(m, 'using_science', return_value=False):
            evidence = m.migration_evidence(self.root, self.home)
            m.write_migration_receipt(self.root, self.home, self.root/'bin/micromamba', evidence)
            self.assertTrue(m.owned_science(self.root))
            with self.assertRaisesRegex(m.InstallError, 'allows update only'):
                m.removal_ownership(self.root)
            self.assertFalse((self.root/'.science-root-owner.json').exists())
            with self.assertRaises(FileExistsError):
                m.write_migration_receipt(self.root, self.home, self.root/'bin/micromamba', evidence)

    def test_stale_reference_and_unknown_executable_not_probed(self):
        binary = self.home/'unknown-micromamba'
        binary.write_text('not Micromamba'); binary.chmod(0o755)
        runner = Mock(side_effect=AssertionError('Untrusted binary invoked'))
        env = {'MAMBA_EXE': str(binary), 'MAMBA_ROOT_PREFIX': str(self.home/'missing'), 'PATH': ''}
        inventory = installer.detect(self.home, env=env, runner=runner)
        self.assertEqual(inventory['executables'], [])
        self.assertIn(str(binary), inventory['unverified_executables'])
        self.assertIn(str(self.home/'missing'), inventory['details'])
        runner.assert_not_called()

    def test_total_remove_requires_exact_path_and_two_exact_approvals(self):
        good = 'Yes, I do understand.'
        with patch.object(sys.stdin, 'isatty', return_value=True), patch.object(sys.stdout, 'isatty', return_value=True):
            for answers, result in [([good, good], True), ([good, good+' '], False), ([good[:-1]], False), ([good.lower()], False)]:
                reader = Mock(side_effect=answers)
                self.assertEqual(installer.confirm_total_removal(self.root, True, reader, Mock()), result)
            reader = Mock(side_effect=[str(self.root)+os.sep, good, good])
            self.assertFalse(installer.confirm_total_removal(self.root, False, reader, Mock()))
            self.assertEqual(reader.call_count, 1)
            self.assertFalse(installer.confirm_total_removal(self.root, True, Mock(side_effect=EOFError), Mock()))
        with patch.object(sys.stdin, 'isatty', return_value=False):
            with self.assertRaisesRegex(m.InstallError, 'interactive terminal'):
                installer.confirm_total_removal(self.root, True, Mock(), Mock())

    def test_multiple_science_roots_require_explicit_selection_unless_active(self):
        other = self.home/'second'; other.mkdir()
        roots = [str(self.root), str(other)]
        info = {'details': {key: {'executables': [str(Path(key)/'bin/micromamba')], 'environments': ['science'],
                                  'unknown': [], 'ownership': 'verified Science environment'} for key in roots},
                'prior': roots, 'registered_external': []}
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(installer.select_inventory_root(info, env={}, reader=Mock(return_value='')), (None, None))
            active = {'CONDA_PREFIX': str(other/'envs/science')}
            root, binary = installer.select_inventory_root(info, env=active, reader=Mock(return_value=''))
            self.assertEqual((root, binary), (other, other/'bin/micromamba'))

    @unittest.skipUnless(os.name == 'posix', 'POSIX mount and descriptor checks required')
    def test_dedicated_total_remove_preserves_other_root_and_external_registry(self):
        other = self.home/'other-mamba'; other.mkdir()
        untouched = other/'keep.txt'; untouched.write_text('other root')
        binary = self.root/'bin/micromamba'; binary.parent.mkdir(); binary.write_text('never executed')
        (self.meta/'history').touch()
        additional = self.root/'envs/analysis/conda-meta'
        additional.mkdir(parents=True)
        (additional/'history').touch()
        self.state.write_text('managed_by='+m.safety.PRODUCT+'\nroot_owned=true\n')
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        identity = self.root.stat(); env_identity = self.prefix.stat()
        m.write_json(self.root/'.science-root-owner.json', dict(managed_by=m.safety.PRODUCT, scope='micromamba-binary',
                     root=str(self.root), executable=str(binary), sha256=digest, created_root_identity=[identity.st_dev, identity.st_ino]))
        m.write_json(self.receipt, dict(managed_by=m.safety.PRODUCT, scope='science-environment', root=str(self.root),
                     prefix=str(self.prefix), micromamba_exe=str(binary), phase='installed',
                     prefix_identity=[env_identity.st_dev, env_identity.st_ino]))
        m.write_json(self.prefix/'.science-owner.json', dict(managed_by=m.safety.PRODUCT, root=str(self.root)))
        registry = self.home/'.conda/environments.txt'; registry.parent.mkdir()
        registry.write_text(str(self.prefix)+'\n'+str(additional.parent)+'\n'+str(other)+'\n')
        inventory = {'details': {str(other): {'unknown': []}}, 'unknown': [], 'external_cache_settings': []}
        with patch.object(m, 'release', return_value={'MicromambaExeSha256': digest}), patch.object(m, 'using_science', return_value=False), patch.object(m.safety, 'config_sources', return_value=[]), patch.dict(os.environ, {}, clear=True):
            m.write_json(self.root/m.DEDICATED_ROOT_RECEIPT, dict(managed_by=m.safety.PRODUCT, scope='dedicated-root',
                         root=str(self.root), identity=[identity.st_dev, identity.st_ino], tree_fingerprint='historical'))
            (self.root/'.inventory-fixture-marker').write_text('managed root with local data')
            plan = m.total_removal_plan(self.root, self.home, inventory)
            self.assertEqual(set(plan['tree']['prefixes']), {self.prefix, additional.parent})
            self.assertEqual(m.apply_total_removal(self.root, self.home, plan, lambda: inventory)[0], str(self.root))
        self.assertFalse(self.root.exists())
        self.assertEqual(untouched.read_text(), 'other root')
        self.assertEqual(registry.read_text(), str(other)+'\n')

    def test_changed_plan_cannot_reach_delete(self):
        with patch.object(m, 'locked', return_value=contextlib.nullcontext()), patch.object(m, 'total_removal_plan', return_value={'changed': True}), patch.object(m.safety, 'remove_tree') as delete:
            with self.assertRaisesRegex(m.InstallError, 'changed after approval'):
                m.apply_total_removal(self.root, self.home, {'changed': False}, dict)
            delete.assert_not_called()

    @unittest.skipUnless(os.name == 'posix', 'POSIX mount and descriptor checks required')
    def test_user_managed_root_allows_arbitrary_payload_and_group_writes(self):
        binary = self.root/'bin/micromamba'; binary.parent.mkdir(); binary.write_text('verified fixture executable')
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        (self.meta/'history').touch()
        external = self.home/'external'; external.mkdir()
        extra = self.prefix/'my-work.ipynb'; extra.touch()
        self.root.chmod(0o775); self.prefix.chmod(0o777)
        (self.root/'.message.txt').write_text('local data')
        displaced = self.prefix/'nested-venv'; displaced.mkdir()
        (displaced/'pyvenv.cfg').touch()
        launcher = self.home/'launcher'; launcher.write_text('outside root')
        (self.home/'.bashrc').write_text(str(self.root))
        inventory = {'details': {}, 'unknown': [], 'external_cache_settings': []}
        with patch.object(m, 'release', return_value={'MicromambaExeSha256': digest}), patch.object(m, 'using_science', return_value=False), patch.object(m.safety, 'config_sources', return_value=[]), patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(m.safety.SafetyError, 'Nested Python/Conda'):
                m.safety.tree_plan(self.prefix)
            plan = m.total_removal_plan(self.root, self.home, inventory)
            self.assertFalse((self.root/'.science-installer.lock').exists())
            m.apply_total_removal(self.root, self.home, plan, lambda: inventory)
        self.assertFalse(self.root.exists())
        self.assertTrue(external.is_dir())
        self.assertEqual(launcher.read_text(), 'outside root')
        self.assertEqual((self.home/'.bashrc').read_text(), str(self.root))

    @unittest.skipUnless(os.name == 'posix', 'POSIX mount and descriptor checks required')
    def test_whole_root_rejects_escapes_mounts_and_missing_delete_rights(self):
        outsider = self.home/'outside'
        outsider.mkdir()
        keep = outsider/'keep'; keep.write_text('untouched')
        link = self.root/'escape'
        link.symlink_to(outsider, target_is_directory=True)
        with self.assertRaisesRegex(m.safety.SafetyError, 'Link leaves'):
            m.safety.tree_plan(self.root, dedicated=True)
        link.unlink()
        with patch.object(m.safety, 'mount_points', return_value=[self.prefix]):
            with self.assertRaisesRegex(m.safety.SafetyError, 'Mounted directory'):
                m.safety.tree_plan(self.root, dedicated=True)
        actual_access = os.access
        with patch.object(m.safety.os, 'access', side_effect=lambda path, mode, **kw:
                          path != self.prefix and actual_access(path, mode, **kw)):
            with self.assertRaisesRegex(m.safety.SafetyError, 'No write/search permission'):
                m.safety.tree_plan(self.root, dedicated=True)
        self.assertEqual(keep.read_text(), 'untouched')

    def test_legacy_adoption_without_receipts_requires_approval_and_rechecks_metadata(self):
        launcher = self.write_v3()
        launcher.write_text('modified legacy launcher')
        self.state.unlink()
        binary = self.root/'bin/micromamba'
        binary.write_text('trusted fixture'); binary.chmod(0o700)
        python = self.prefix/'bin/python'; python.parent.mkdir(); python.touch(mode=0o700)
        keep = self.prefix/'personal.txt'; keep.write_text('keep')
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        with patch.object(m, 'release', return_value={'MicromambaExeSha256': digest}), \
             patch.object(sys.stdin, 'isatty', return_value=True), \
             patch.object(m, 'using_science', return_value=False), contextlib.redirect_stdout(io.StringIO()):
            with patch.object(sys.stdout, 'isatty', return_value=True):
                with self.assertRaises(installer.PreparationPending):
                    installer.review_migration(self.root, self.home, binary, Mock(return_value='no'))
                evidence = installer.review_migration(self.root, self.home, binary, Mock(return_value='yes'))
            self.assertEqual(evidence['format'], 'approved-existing-science')
            self.assertFalse(self.receipt.exists())
            history = self.meta/'history'; original = history.read_bytes()
            history.write_bytes(original + b'changed\n')
            with self.assertRaisesRegex(m.InstallError, 'changed after review'):
                m.write_migration_receipt(self.root, self.home, binary, evidence)
            history.write_bytes(original)
            m.write_migration_receipt(self.root, self.home, binary, evidence)
            self.assertTrue(m.owned_science(self.root))
            with self.assertRaisesRegex(m.InstallError, 'update only'):
                m.removal_ownership(self.root)
        self.assertEqual(keep.read_text(), 'keep')
        self.assertFalse((self.root/'.science-root-owner.json').exists())

    def test_adopted_science_can_complete_an_in_place_noop(self):
        binary = self.root/'bin/micromamba'
        binary.parent.mkdir()
        binary.write_text('never execute'); binary.chmod(0o700)
        python = self.prefix/'bin/python'; python.parent.mkdir(); python.touch(mode=0o700)
        (self.meta/'history').write_text('+python-3.14.10-fixture\n')
        config = m.release()
        config['MicromambaExeSha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        variants = {'python': ('3.14.10', 'fixture'), 'spyder': (config['Spyder'], 'fixture'),
                    'opencv': (config['OpenCV'], 'qt6_fixture'), 'ffmpeg': (config['FFmpeg'], 'gpl_fixture'),
                    'apache-arrow-proc': ('20.0.0', 'cpu'), 'python_abi': ('3.14.0', '0_cp314')}
        for request in config['ScientificPackages']:
            name = m.spec_name(request)
            version, build = variants.get(name, ('1.0.0', 'fixture'))
            row = dict(name=name, version=version, build=build, subdir='linux-64', sha256='a'*64)
            (self.meta/f'{name}-{version}-{build}.json').write_text(json.dumps(row))
        keep = self.root/'envs/analysis/notes'; keep.parent.mkdir(); keep.write_text('separate environment')
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, '{"success":true}', ''))
        with patch.object(m, 'release', return_value=config), patch.object(m, 'using_science', return_value=False), \
             contextlib.redirect_stdout(io.StringIO()):
            evidence = m.adoption_evidence(self.root, self.home, binary)
            m.write_migration_receipt(self.root, self.home, binary, evidence)
            self.assertFalse(m.sync(self.root, config, runner=runner, existing=True, home=self.home, mm=binary))
            self.assertEqual(m.ownership_json(self.receipt)['phase'], 'installed')
            self.assertTrue(m.owned_science(self.root))
        argv = runner.call_args.args[0]
        self.assertEqual(argv[1], 'update')
        self.assertEqual(argv[argv.index('-p') + 1], self.prefix)
        self.assertIn('--dry-run', argv)
        runner.assert_called_once()
        self.assertEqual(keep.read_text(), 'separate environment')

    def test_saved_optional_config_preserved_for_other_root(self):
        path = self.home/'science-release.json'
        cfg = m.science_config.defaults(ROOT/'linux'); cfg['ScientificPackages'].append("pytorch[build='cpu*']")
        before = json.dumps(cfg).encode(); path.write_bytes(before)
        reader = Mock(return_value='yes'); messages = []
        m.science_config.review_new_root_configuration(ROOT/'linux', self.home/'new', [str(self.root)], reader, messages.append, path)
        reader.assert_not_called()
        self.assertEqual(path.read_bytes(), before)
        self.assertIn('CPU', '\n'.join(messages))
        m.science_config.review_new_root_configuration(ROOT/'linux', self.home/'new', [], reader, messages.append, path)
        self.assertEqual(m.science_config.read_json(path), m.science_config.defaults(ROOT/'linux'))
        self.assertEqual(next(self.home.glob('*pre-reset*')).read_bytes(), before)

    def test_native_timeout_exit_and_bounded_output(self):
        argv = [sys.executable, '-c', 'import sys; print("json"); print("warning",file=sys.stderr); sys.exit(17)']
        result = installer.run_package_process(argv, timeout=10)
        self.assertEqual((result.returncode, result.stdout.strip(), result.stderr.strip()), (17, 'json', 'warning'))
        result = installer.run_package_process([sys.executable, '-c', 'print("x"*10000)'], capture_limit=32)
        self.assertNotEqual(result.returncode, 0); self.assertEqual(result.stdout, '')
        self.assertIn('Capture limit exceeded', result.stderr)
        with self.assertRaises(subprocess.TimeoutExpired):
            installer.run_package_process([sys.executable, '-c', 'import time; time.sleep(20)'], timeout=.2)


if __name__ == '__main__':
    unittest.main()
