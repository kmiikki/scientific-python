"""Exercise version reporting, existing configuration and the extracted bundles."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DistributionTests(unittest.TestCase):
    def test_platform_versions_and_extracted_integrity(self):
        with tempfile.TemporaryDirectory(prefix='science-distribution-') as directory:
            temp = Path(directory)
            subprocess.run([sys.executable, '-B', str(ROOT / 'tools/build_distributions.py'), directory],
                           check=True, capture_output=True, text=True, timeout=45)
            for platform, launcher in [('linux', '07-test-usb-camera.sh'), ('windows', '07-TEST-USB-CAMERA.cmd')]:
                name = f'scientific-python-v0.9.1-{platform}'
                with ZipFile(temp / (name + '.zip')) as archive:
                    self.assertIsNone(archive.testzip())
                    self.assertIn(f'{name}/{platform}/{launcher}', archive.namelist())
                    self.assertIn(f'{name}/shared/science-camera.py', archive.namelist())
                    archive.extractall(temp)
                bundle = temp / name / platform
                meta = json.loads((bundle / 'science-installer-release.json').read_text())
                self.assertEqual(meta['InstallerVersion'], '0.9.1')
                for line in (bundle / 'SHA256SUMS.txt').read_text().splitlines():
                    digest, entry = line.split('  ', 1)
                    path = (bundle.parent if entry.startswith('shared/') else bundle) / entry
                    self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest, entry)
            if os.name == 'posix':
                menu = temp / 'scientific-python-v0.9.1-linux/linux/00-menu.sh'
                run = subprocess.run(['bash', menu], input='q\n', capture_output=True, text=True, timeout=20)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn('Scientific Python 0.9.1', run.stdout)
                self.assertIn('U  USB Camera Test (optional)', run.stdout)

    @unittest.skipUnless(os.name == 'posix', 'Ubuntu launcher targets a POSIX environment')
    def test_camera_launcher_uses_selected_science_python(self):
        installer = load('camera_linux_launcher', ROOT / 'linux/science-install.py')
        with tempfile.TemporaryDirectory(prefix='science-camera-root-') as directory:
            root = Path(directory) / 'µ caméra'
            prefix = root / 'envs/science'
            python = prefix / 'bin/python'
            python.parent.mkdir(parents=True)
            python.touch(mode=0o700)
            with patch.object(installer.m, 'platform_guard'), \
                 patch.object(installer, 'detect', return_value={'prior': [str(root), '/other']}), \
                 patch.object(installer.os, 'execve') as execute:
                installer.camera_launcher(['--root', str(root), '--list', '--json'])
            executable, argv, environment = execute.call_args.args
            self.assertEqual(executable, python)
            self.assertEqual(argv, [str(python), '-IB', str(ROOT / 'shared/science-camera.py'),
                                    '--list', '--json', '--prefix', str(prefix)])
            self.assertEqual(environment['PATH'].split(os.pathsep)[0], str(python.parent))

    def test_existing_configuration_and_versionless_schema(self):
        config = load('camera_release_configuration', ROOT / 'linux/science_config.py')
        package_config = config.defaults(ROOT / 'linux')
        package_config['ScientificPackages'] = [
            'scikit-image>=0.25' if config.spec_name(spec) == 'scikit-image' else spec
            for spec in package_config['ScientificPackages']
        ] + ['pytorch=*=cpu*']
        existing = json.dumps(package_config).encode()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'science-release.json'
            path.write_bytes(existing)
            value = config.effective(ROOT / 'linux', path)
            self.assertEqual(value['InstallerVersion'], '0.9.1')
            self.assertEqual(value['ScientificPackages'], package_config['ScientificPackages'])
            self.assertEqual(path.read_bytes(), existing)
            self.assertEqual(value['SchemaVersion'], 1)


if __name__ == '__main__':
    unittest.main()
