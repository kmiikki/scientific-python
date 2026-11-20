"""Environment ownership must be checked independently of root ownership."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('science_manager_ownership', ROOT / 'linux/science-manager.py')
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class UbuntuOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix='science-ownership-')
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name) / 'mamba'
        self.prefix = self.root / 'envs/science'
        self.meta = self.prefix / 'conda-meta'
        self.meta.mkdir(parents=True)
        self.receipt = self.root / '.science-env-owner.json'
        self.marker = self.prefix / '.science-owner.json'
        self.state = self.root / '.scientific-python-installer-state'
        self.other = self.root / 'envs/independent'
        self.other.mkdir()
        (self.other / 'user.txt').write_text('independent')
        info = self.prefix.stat()
        self.proof = {
            'managed_by': 'scientific-python-ubuntu',
            'scope': 'science-environment',
            'root': str(self.root),
            'prefix': str(self.prefix),
            'micromamba_exe': str(self.root / 'bin/micromamba'),
            'phase': 'installed',
            'prefix_identity': [info.st_dev, info.st_ino],
        }
        self.record = {
            'name': 'python', 'version': '3.14.0', 'build': 'h0_0',
            'subdir': 'linux-64', 'sha256': 'a' * 64,
        }
        self.write_state()
        manager.write_json(self.meta / 'python.json', self.record)
        (self.meta / 'history').write_text('+python-3.14.0-h0_0\n')

    def write_state(self, **changes):
        state = {
            'managed_by': 'scientific-python-ubuntu',
            'status': 'complete',
            'root': str(self.root),
            'science': str(self.prefix),
            'mode': 'existing',
            'root_owned': 'false',
            'micromamba_exe': self.proof['micromamba_exe'],
            'release_fingerprint': 'b' * 64,
            'package_fingerprint': manager.package_fingerprint({'python': self.record}),
        } | changes
        manager.atomic_bytes(self.state, ''.join(f'{key}={value}\n' for key, value in state.items()).encode(), 0o600)

    def write_receipt(self, **changes):
        manager.write_json(self.receipt, self.proof | changes)

    def mark_prefix(self):
        manager.write_json(self.marker, {'managed_by': 'scientific-python-ubuntu', 'root': str(self.root)})

    def test_managed_environment_in_unowned_root(self):
        self.write_receipt()
        self.mark_prefix()
        manager.guard_root(self.root, existing=True)
        manager.guard_science(self.root)
        self.assertTrue(manager.removal_ownership(self.root))
        with self.assertRaisesRegex(manager.InstallError, 'Existing Micromamba installations'):
            manager.root_removal_plan(self.root)
        self.assertFalse((self.root / '.science-root-owner.json').exists())
        self.assertEqual((self.other / 'user.txt').read_text(), 'independent')

    def test_legacy_receipt_requires_matching_state_and_conda_records(self):
        self.write_receipt()
        self.assertTrue(manager.removal_ownership(self.root))
        self.assertFalse(self.marker.exists())
        manager.write_json(self.meta / 'python.json', self.record | {'build': 'changed'})
        with self.assertRaisesRegex(manager.InstallError, 'installed packages disagree'):
            manager.guard_science(self.root)

    def test_existing_v090_ownership_records_remain_usable(self):
        self.write_receipt()
        self.write_state(installer_version='0.9.0-dev')
        original = (self.state.read_bytes(), self.receipt.read_bytes())
        self.assertEqual(manager.science_config.read_json(ROOT / 'linux/science-installer-release.json')['InstallerVersion'],
                         '0.9.2')
        self.assertTrue(manager.removal_ownership(self.root))
        manager.guard_science(self.root)
        self.assertEqual((self.state.read_bytes(), self.receipt.read_bytes()), original)

    def test_state_or_prefix_marker_alone_cannot_grant_ownership(self):
        for marker in (False, True):
            with self.subTest(marker=marker):
                if marker:
                    self.mark_prefix()
                with self.assertRaisesRegex(manager.InstallError, r'matching \.science-env-owner\.json'):
                    manager.removal_ownership(self.root)
        self.assertFalse(self.receipt.exists())
        self.assertTrue((self.meta / 'python.json').exists())

    def test_missing_legacy_state_blocks_receipt_only(self):
        self.write_receipt()
        self.state.unlink()
        with self.assertRaisesRegex(manager.InstallError, 'completed installer state'):
            manager.guard_science(self.root)

    def test_conflicting_paths_scope_and_installer_state_fail_closed(self):
        for field, value in [('root', '/foreign'), ('prefix', str(self.other)), ('scope', 'micromamba-binary')]:
            with self.subTest(field=field):
                self.write_receipt(**{field: value})
                with self.assertRaisesRegex(manager.InstallError, 'different root, prefix or scope'):
                    manager.guard_science(self.root)
        self.write_receipt()
        self.write_state(science=str(self.other))
        with self.assertRaisesRegex(manager.InstallError, 'state disagrees'):
            manager.guard_science(self.root)

    def test_replaced_prefix_is_refused_even_with_copied_marker(self):
        self.write_receipt()
        self.mark_prefix()
        original = self.prefix.with_name('original-science')
        self.prefix.rename(original)
        self.prefix.mkdir()
        self.mark_prefix()
        with self.assertRaisesRegex(manager.InstallError, 'directory identity differs'):
            manager.removal_ownership(self.root)

    def test_symlinked_prefix_and_unsafe_metadata_are_refused(self):
        self.write_receipt()
        self.receipt.chmod(0o666)
        with self.assertRaisesRegex(manager.InstallError, 'Unsafe permissions'):
            manager.guard_science(self.root)
        self.receipt.chmod(0o600)
        self.prefix.rename(self.prefix.with_name('original-science'))
        self.prefix.symlink_to(self.other, target_is_directory=True)
        with self.assertRaisesRegex(manager.InstallError, 'redirection refused'):
            manager.removal_ownership(self.root)

    def test_download_reservation_is_limited_to_empty_skeleton(self):
        self.write_receipt(phase='download', prefix_identity=None)
        self.mark_prefix()
        self.assertFalse(manager.owned_science(self.root))
        (self.meta / 'python.json').unlink()
        (self.meta / 'history').write_bytes(b'')
        self.assertTrue(manager.owned_science(self.root))
