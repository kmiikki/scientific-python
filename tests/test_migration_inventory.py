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
            with m.locked(self.root):
                m.seal_dedicated_root(self.root)
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
    def test_user_managed_root_lock_and_unknown_payload(self):
        binary = self.root/'bin/micromamba'; binary.parent.mkdir(); binary.write_text('verified fixture executable')
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        (self.meta/'history').touch()
        external = self.home/'external'; external.mkdir()
        extra = self.prefix/'my-work.ipynb'; extra.touch()
        inventory = {'details': {}, 'unknown': [], 'external_cache_settings': []}
        with patch.object(m, 'release', return_value={'MicromambaExeSha256': digest}), patch.object(m, 'using_science', return_value=False), patch.object(m.safety, 'config_sources', return_value=[]), patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(m.InstallError, 'Unidentified environment entry'):
                m.total_removal_plan(self.root, self.home, inventory)
            extra.unlink()
            plan = m.total_removal_plan(self.root, self.home, inventory)
            self.assertFalse((self.root/'.science-installer.lock').exists())
            m.apply_total_removal(self.root, self.home, plan, lambda: inventory)
        self.assertFalse(self.root.exists())
        self.assertTrue(external.is_dir())

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

    def test_native_heartbeat_exit_and_bounded_output(self):
        output = Mock()
        argv = [sys.executable, '-c', 'import sys,time; print("json"); print("warning",file=sys.stderr); time.sleep(.4); sys.exit(17)']
        result = installer.run_package_process(argv, interval=.05, timeout=10, output=output)
        self.assertEqual((result.returncode, result.stdout.strip(), result.stderr.strip()), (17, 'json', 'warning'))
        self.assertTrue(any('process: ACTIVE' in item.args[0] for item in output.call_args_list))
        result = installer.run_package_process([sys.executable, '-c', 'print("x"*10000)'], capture_limit=32)
        self.assertNotEqual(result.returncode, 0); self.assertEqual(result.stdout, '')
        self.assertIn('Capture limit exceeded', result.stderr)
        with self.assertRaises(subprocess.TimeoutExpired):
            installer.run_package_process([sys.executable, '-c', 'import time; time.sleep(20)'], timeout=.2, output=Mock())


if __name__ == '__main__':
    unittest.main()
