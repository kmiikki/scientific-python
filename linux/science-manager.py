#!/usr/bin/env python3
"""Ubuntu V4 package policy and user-local artifacts; Python standard library only."""
import argparse
import ast
import configparser
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request

BUNDLE = Path(__file__).resolve().parent


def helper(name):
    spec = importlib.util.spec_from_file_location('science_' + name, BUNDLE / ('science_' + name + '.py'))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value


# File-loaded managers do not inherit this directory in sys.path. Resolve
# project dependencies explicitly; never depend on the caller's working directory.
science_integrity = helper('integrity')
try:
    science_integrity.verify(BUNDLE)
except (ValueError, OSError) as exc:
    raise SystemExit('ERROR: ' + str(exc)) from None
science_config = helper('config')
MARKER = 'managed_by=scientific-python-ubuntu'
PATH_BEGIN = b'# >>> scientific-python command PATH >>>'
PATH_END = b'# <<< scientific-python command PATH <<<'


_safety_spec = importlib.util.spec_from_file_location('science_safety', BUNDLE / 'science_safety.py')
safety = importlib.util.module_from_spec(_safety_spec)
_safety_spec.loader.exec_module(safety)
InstallError = safety.SafetyError

_tx_spec = importlib.util.spec_from_file_location('science_transaction', BUNDLE / 'science_transaction.py')
tx = importlib.util.module_from_spec(_tx_spec)
_tx_spec.loader.exec_module(tx)
tx.TransactionError = InstallError


processes = helper('processes')
desktop_tools = helper('desktop')
lifecycle = helper('lifecycle')


class OperationBlocked(InstallError):
    pass


_HELD_LOCKS = set()


class UsageBlocked(InstallError):
    def __init__(self, report, operation='modified'):
        self.report = report
        super().__init__(processes.guidance(report, operation))


def raise_busy(prefix, operation='modified'):
    report = processes.inspect(prefix)
    if report['status'] != 'BLOCKED':
        report['status'] = 'BLOCKED'
        report['uncertainties'].append('A usage guard reported a concurrent science process; recheck before continuing.')
    raise UsageBlocked(report, operation)


def release(directory=BUNDLE):
    try: return science_config.effective(directory)
    except science_config.ConfigError as exc: raise InstallError(str(exc)) from exc


def version(text):
    if not re.fullmatch(r'\d+(?:\.\d+){0,3}', str(text)):
        raise InstallError('Unreviewed non-stable package version.')
    return tuple(int(p) for p in str(text).split('.')) + (0,) * (4 - len(str(text).split('.')))


def specs(config, installed=None):
    science_config.require_workflow(config)
    # User requests remain unchanged; extra media floors preserve the existing safety contract.
    result = list(config['ScientificPackages'])
    for name in ['opencv', 'ffmpeg']:
        if installed and name in installed:
            result.append(name + '>=' + installed[name]['version'])
    return result


def spec_name(value):
    return science_config.spec_name(value)


def records(prefix):
    result = {}
    for file in (Path(prefix) / 'conda-meta').glob('*.json'):
        record = json.loads(file.read_text(encoding='utf-8'))
        if record.get('name'):
            if record['name'] in result:
                raise InstallError('Duplicate installed package records: ' + record['name'])
            result[record['name']] = record
    return result


def history_specs(prefix):
    history = Path(prefix) / 'conda-meta' / 'history'
    if not history.is_file():
        return None
    requested = set()
    seen = False
    try:
        for line in history.read_text(encoding='utf-8').splitlines():
            if line.startswith(('# update specs:', '# install specs:', '# remove specs:', '# scientific-python requested specs:')):
                values = ast.literal_eval(line.split(':', 1)[1].strip())
                if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                    return None
                names = {spec_name(v) for v in values}
                if line.startswith('# scientific-python requested specs:'):
                    requested = names
                elif line.startswith('# remove specs:'):
                    requested -= names
                else:
                    requested |= names
                seen = True
    except (OSError, ValueError, SyntaxError, InstallError):
        return None
    return requested if seen else None


def check_plan(plan, before, config, explicit=None):
    if not plan.get('success'):
        raise InstallError('No compatible conda-forge solution. No package changes started.')
    after = dict(before)
    actions = plan.get('actions') or {}
    links = {r['name']: r for r in actions.get('LINK', [])}
    removed = {r['name'] for r in actions.get('UNLINK', [])}
    for name in removed:
        after.pop(name, None)
    after.update(links)
    required = {spec_name(s) for s in specs(config)}
    missing = required - set(after)
    if missing:
        raise InstallError('Incomplete plan: missing ' + ', '.join(sorted(missing)))
    for name, key, major, build in [('opencv', 'OpenCV', 5, 'qt6'), ('ffmpeg', 'FFmpeg', 9, 'gpl')]:
        record = after[name]
        v = version(record['version'])
        floor = max(version(config[key]), version(before[name]['version']) if name in before else (0,))
        if v[0] != major or v < floor:
            raise InstallError('Refusing downgrade or wrong major version of ' + name + '.')
        if not record.get('build', record.get('build_string', '')).startswith(build):
            raise InstallError('Wrong native variant for ' + name + '.')
    if version(after['python']['version'])[:2] != version(config['Python'])[:2]:
        raise InstallError('Python 3.14 is required.')
    if version(after['spyder']['version']) != version(config['Spyder']):
        raise InstallError('Incorrect Spyder version.')
    abi = after['python_abi'].get('build', after['python_abi'].get('build_string', ''))
    if not abi.endswith('_cp' + config['Python'].replace('.', '')):
        raise InstallError('Ordinary GIL CPython ABI is required.')
    if after['apache-arrow-proc'].get('build', after['apache-arrow-proc'].get('build_string')) != 'cpu':
        raise InstallError('CPU Arrow is required.')
    torch_backend = science_config.pytorch_backend(config['ScientificPackages'])
    if torch_backend == 'conflicting':
        raise InstallError('The PyTorch requests specify conflicting backends.')
    if torch_backend in ('cpu', 'cuda'):
        torch = after.get('pytorch', {})
        build = torch.get('build', torch.get('build_string', ''))
        if not build.startswith(torch_backend):
            raise InstallError('The solver did not select the requested PyTorch backend: ' + torch_backend.upper())
    truly_removed = removed - set(links)
    protected = (set(before) if explicit is None else explicit) - required
    blocked = truly_removed & protected
    if blocked:
        raise InstallError('Refusing removal of user packages: ' + ', '.join(sorted(blocked)))
    return after


def atomic_bytes(path, content, mode=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.science-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if mode is not None:
            os.chmod(temporary, mode)
        elif path.exists():
            os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path, value):
    atomic_bytes(path, (json.dumps(value, indent=2, ensure_ascii=True) + '\n').encode(), 0o600)


def read_state(root):
    state = Path(root) / '.scientific-python-installer-state'
    if not state.is_file():
        return {}
    return dict(line.split('=', 1) for line in state.read_text(encoding='utf-8').splitlines() if '=' in line)


def guard_root(root, home=None, allow_new=False, existing=False):
    root = Path(root)
    home = Path(home) if home is not None else Path.home()
    if not root.is_absolute() or any(c in str(root) for c in "\n\r\t=") or '..' in root.parts:
        raise InstallError('Use an absolute root path without control characters, = or .. components.')
    if root in [Path('/'), home, Path('/home'), Path('/usr'), Path('/tmp'), Path('/var'), Path('/opt')]:
        raise InstallError('Unsafe root: select a dedicated Micromamba directory.')
    if 'envs' in root.parts:
        raise InstallError('A Micromamba root cannot be inside an environment directory.')
    for part in [root, *root.parents]:
        if part.is_symlink():
            raise InstallError('Symlinked root paths are refused; select the real path explicitly.')
    if root.exists() and not root.is_dir():
        raise InstallError('Root is not a directory.')
    if root.exists():
        state = read_state(root)
        if (root / '.scientific-python-installer-state').exists() and state.get('managed_by') != 'scientific-python-ubuntu':
            raise InstallError('A foreign installer state file will not be overwritten.')
        if not existing and (state.get('mode') == 'existing' or state.get('root_owned') == 'false'):
            raise InstallError('This root belongs to an Existing installation; use Existing mode.')
        if not existing and read_state(root).get('managed_by') != 'scientific-python-ubuntu':
            raise InstallError('Existing unmanaged root: select Existing mode.')
        for child in ['bin', 'pkgs', 'envs', 'tmp', 'share', 'envs/science', '.scientific-python-installer-state',
                      '.science-installer.lock', '.science-attempt.json', '.science-update-plan.json',
                      'science-runtime.json', 'science-diagnostics.json', 'science-packages.json',
                      'envs/science/conda-meta', '.science-transactions', '.science-startup', '.science-shells', 'science-removal.json', 'science-other-environments.json', 'science-spyder-startup.json', 'science-fontconfig-repair.json', '.science-root-owner.json', '.science-env-owner.json', '.science-launchers.json', '.science-launch', 'science-launch-context.json']:
            target = root / child
            if target.is_symlink() or not target.resolve().is_relative_to(root.resolve()):
                raise InstallError('A managed path is symlinked or points outside the selected root.')
    elif not allow_new:
        raise InstallError('Selected root does not exist.')
    parent = root if root.exists() else next(p for p in root.parents if p.exists())
    if not os.access(parent, os.W_OK | os.X_OK):
        raise InstallError('Selected root is not writable.')
    return root


def ownership_file(path, *, package_metadata=False):
    """Read user-owned evidence and ensure the file identity remains stable."""
    safety.plain_path(path)
    info = path.lstat()
    writable_mask = 0o002 if package_metadata else 0o022
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & writable_mask or info.st_nlink != 1:
        raise InstallError('Unsafe permissions or file type for ownership evidence: ' + str(path))
    content, identity, mode = safety.read_regular(path)
    if identity != (info.st_dev, info.st_ino) or mode != stat.S_IMODE(info.st_mode):
        raise InstallError('Ownership evidence changed while being read: ' + str(path))
    return content


def ownership_json(path):
    value = json.loads(ownership_file(path))
    if not isinstance(value, dict):
        raise InstallError('Expected an ownership object: ' + str(path))
    return value


def verify_legacy_science(root, prefix, receipt):
    state_path = root / '.scientific-python-installer-state'
    if not os.path.lexists(state_path):
        raise InstallError('Legacy environment ownership requires the completed installer state.')
    pairs = [line.split('=', 1) for line in ownership_file(state_path).decode().splitlines() if '=' in line]
    state = dict(pairs)
    expected = {'managed_by': safety.PRODUCT, 'root': str(root), 'science': str(prefix),
                'status': 'complete', 'micromamba_exe': receipt['micromamba_exe']}
    if len(state) != len(pairs) or any(state.get(key) != value for key, value in expected.items()):
        raise InstallError('Legacy installer state disagrees with the environment ownership receipt.')
    if not re.fullmatch(r'[0-9a-f]{64}', state.get('release_fingerprint', '')):
        raise InstallError('Legacy installer state lacks its release fingerprint.')
    safety.plain_path(prefix / 'conda-meta')
    if not ownership_file(prefix / 'conda-meta/history', package_metadata=True).strip():
        raise InstallError('Legacy environment lacks a populated Conda history.')
    installed = {}
    for file in (prefix / 'conda-meta').glob('*.json'):
        record = json.loads(ownership_file(file, package_metadata=True))
        name = record.get('name') if isinstance(record, dict) else None
        if not isinstance(name, str) or not name or name in installed:
            raise InstallError('Legacy environment contains ambiguous Conda package records.')
        installed[name] = record
    if not installed or state.get('package_fingerprint') != package_fingerprint(installed):
        raise InstallError('Legacy installed packages disagree with the completed installer state.')


LEGACY_V3_LAUNCHER = 'f39fd7cfbfaedde52a725eb883983ac99e091c94d77da89e8a9e63ea40884ba7'
LEGACY_V3_BINARY_HASHES = frozenset({
    '9689782d863c05a1bf5d2d371ba527104e7a4eb4310c1637d8653b751aed9c82',
    '77b7790ec97f64581118f103585b175df4306f95829b0fa6bfe4a19cc88a1182',
})
LEGACY_V3_SPECS = tuple('''python=3.14 apache-arrow-proc=*=cpu numpy scipy pandas matplotlib seaborn
    sympy statsmodels scikit-learn scikit-image opencv pillow imageio xarray h5py netcdf4 pyarrow
    openpyxl xlsxwriter jupyterlab ipykernel ipython spyder=6.1.7 numba tqdm pint uncertainties pyserial pip'''.split())


def check_legacy_directory(directory):
    safety.plain_path(directory)
    st = directory.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
        raise InstallError('Legacy directory ownership or permissions are ambiguous: ' + str(directory))


def migration_evidence(root, home):
    """Read evidence only. Missing or inconsistent evidence never implies ownership."""
    root, home = Path(root), Path(home)
    prefix = root / 'envs/science'
    for directory in (root, root / 'envs', prefix, prefix / 'conda-meta'):
        check_legacy_directory(directory)
    state_bytes = ownership_file(root / '.scientific-python-installer-state')
    pairs = [line.split('=', 1) for line in state_bytes.decode().splitlines()]
    if any(len(pair) != 2 for pair in pairs) or len({pair[0] for pair in pairs}) != len(pairs):
        raise InstallError('Legacy installer state contains invalid or repeated keys.')
    state = dict(pairs)
    marker = prefix / '.science-owner.json'
    marker_exists = os.path.lexists(marker)
    if marker_exists and ownership_json(marker) != {'managed_by': safety.PRODUCT, 'root': str(root)}:
        raise InstallError('The Science prefix has a conflicting ownership marker.')
    history = ownership_file(prefix / 'conda-meta/history', package_metadata=True)
    if not history.strip():
        raise InstallError('Legacy environment lacks a populated Conda history.')
    if state.get('status') == 'complete':
        # A current-style state requires both the recorded package fingerprint
        # and the independent prefix marker. The root receipt is out of scope.
        executable = state.get('micromamba_exe', '')
        if not marker_exists or not Path(executable).is_absolute():
            raise InstallError('Completed installer state also requires its matching prefix marker and executable path.')
        verify_legacy_science(root, prefix, {'micromamba_exe': executable})
        provenance = 'completed-installer-state'
        recorded = state['package_fingerprint']
    else:
        expected = dict(managed_by=safety.PRODUCT, installer_version='ubuntu-lts-v3', micromamba_version='2.8.1',
                        python_spec='3.14', spyder_spec='6.1.7', layout='home', root=str(root), science=str(prefix))
        if state != expected or root != home / 'micromamba':
            raise InstallError('Legacy installer state is not a supported completed format for this root.')
        launcher = ownership_file(root / 'bin/science-spyder')
        if hashlib.sha256(launcher).hexdigest() != LEGACY_V3_LAUNCHER:
            raise InstallError('The V3 home launcher differs from the archived installer launcher.')
        tail = ['-y', '-n', 'science', '--override-channels', '-c', 'conda-forge', *LEGACY_V3_SPECS]
        commands = [shlex.split(line[7:]) for line in history.decode().splitlines() if line.startswith('# cmd: ')]
        if not any(args in ([str(root / 'bin/micromamba'), verb, *tail] for verb in ('create', 'install')) for args in commands):
            raise InstallError('Conda history does not record the archived V3 create/install command and package requests.')
        installed = {}
        for path in (prefix / 'conda-meta').glob('*.json'):
            item = json.loads(ownership_file(path, package_metadata=True))
            if not isinstance(item, dict):
                raise InstallError('Invalid installed package record: ' + path.name)
            name, version_, build = (item.get(key) for key in ('name', 'version', 'build'))
            if (not all(isinstance(value, str) and value for value in (name, version_, build)) or name in installed
                    or path.name != '{}-{}-{}.json'.format(name, version_, build)):
                raise InstallError('Ambiguous installed package identity: ' + path.name)
            installed[name] = item
        for spec in LEGACY_V3_SPECS:
            name = spec.split('=', 1)[0]
            item = installed.get(name, {})
            if not re.fullmatch(r'https://conda\.anaconda\.org/conda-forge/(?:linux-64|noarch)/[^/?#]+', item.get('url') or ''):
                raise InstallError('V3 package is missing or its conda-forge provenance cannot be verified: ' + name)
        if not (installed['python']['version'].startswith('3.14.') and installed['spyder']['version'] == '6.1.7'
                and installed['apache-arrow-proc']['build'] == 'cpu'):
            raise InstallError('Installed Python, Spyder or Arrow build differs from the archived V3 configuration.')
        provenance = 'ubuntu-lts-v3'
        recorded = package_fingerprint(installed)
    identity = prefix.lstat()
    return {'format': provenance, 'prefix_identity': [identity.st_dev, identity.st_ino],
            'state_sha256': hashlib.sha256(state_bytes).hexdigest(), 'history_sha256': hashlib.sha256(history).hexdigest(),
            'package_fingerprint': recorded}


def write_migration_receipt(root, home, mm, approved_evidence):
    """Publish a complete, environment-only receipt without replacing anything."""
    root, mm = Path(root), Path(mm)
    prefix = root / 'envs/science'
    with locked(root, reuse=True):
        if using_science(prefix):
            raise_busy(prefix, 'migrated')
        if migration_evidence(root, home) != approved_evidence:
            raise InstallError('Legacy evidence changed after review; retry the migration.')
        receipt = {'managed_by': safety.PRODUCT, 'scope': 'science-environment', 'root': str(root),
                   'prefix': str(prefix), 'micromamba_exe': str(mm), 'phase': 'migration', **approved_evidence}
        with safety.directory_fd(root) as anchor, tempfile.NamedTemporaryFile(dir=root) as temp:
            temp.write((json.dumps(receipt, indent=2) + '\n').encode()); temp.flush(); os.fsync(temp.fileno())
            info = os.fstat(anchor)
            if (info.st_dev, info.st_ino) != (root.stat().st_dev, root.stat().st_ino):
                raise InstallError('Legacy root changed after review.')
            os.link(Path(temp.name).name, '.science-env-owner.json', src_dir_fd=anchor, dst_dir_fd=anchor, follow_symlinks=False)


def owned_science(root):
    root = Path(root)
    prefix = root / 'envs/science'
    receipt_path = root / '.science-env-owner.json'
    owner_path = prefix / '.science-owner.json'
    safety.plain_path(prefix, missing=True)
    if not os.path.lexists(receipt_path):
        return False
    receipt = ownership_json(receipt_path)
    expected = {'managed_by': safety.PRODUCT, 'scope': 'science-environment',
                'root': str(root), 'prefix': str(prefix)}
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise InstallError('Environment ownership receipt has a different root, prefix or scope.')
    phase = receipt.get('phase')
    executable = receipt.get('micromamba_exe')
    if phase not in ('download', 'transaction', 'installed', 'migration') or not isinstance(executable, str) or not Path(executable).is_absolute():
        raise InstallError('Environment ownership receipt has an invalid phase or executable path.')
    if not prefix.exists():
        return phase != 'migration'  # Migration never authorizes a different/absent prefix.
    info = prefix.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o002:
        raise InstallError('Science directory ownership or permissions are ambiguous.')
    identity = receipt.get('prefix_identity')
    if not (phase == 'download' and identity is None) and identity != [info.st_dev, info.st_ino]:
        raise InstallError('Science directory identity differs from the ownership receipt.')
    if phase == 'migration':
        evidence = migration_evidence(root, root.parent if receipt.get('format') == 'ubuntu-lts-v3' else Path.home())
        if any(receipt.get(key) != value for key, value in evidence.items()):
            raise InstallError('Legacy evidence changed since migration. The environment is preserved.')
        return True
    has_marker = os.path.lexists(owner_path)
    if has_marker and ownership_json(owner_path) != {'managed_by': safety.PRODUCT, 'root': str(root)}:
        raise InstallError('Science directory marker disagrees with the environment ownership receipt.')
    if phase == 'download':
        # The downloader reservation authorizes only an empty environment skeleton.
        allowed = {'conda-meta', 'conda-meta/history', '.science-owner.json'}
        paths = set()
        for item in prefix.rglob('*'):
            safety.plain_path(item)
            paths.add(str(item.relative_to(prefix)))
        history = prefix / 'conda-meta/history'
        return paths <= allowed and (not history.exists() or ownership_file(history, package_metadata=True) == b'')
    if has_marker:
        return True
    if phase != 'installed':
        raise InstallError('Interrupted Science transaction lacks its directory ownership marker.')
    verify_legacy_science(root, prefix, receipt)
    return True


def guard_science(root):
    prefix = Path(root) / 'envs/science'
    if prefix.exists() and not owned_science(root):
        raise InstallError('Science ownership is unverified. A matching .science-env-owner.json receipt is required; the environment was preserved.')


def approve_plan(plan, before, after):
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return False
    while True:
        answer = input('Apply these package changes? [y/N/full]: ').strip().lower()
        if answer == 'full':
            print(json.dumps(plan, indent=2)); continue
        return answer == 'y'


def plan_summary(plan, before):
    actions = plan.get('actions') or {}
    links = {r['name']: r for r in actions.get('LINK', [])}
    unlinks = {r['name']: r for r in actions.get('UNLINK', [])}
    counts = dict(install=0, upgrade=0, downgrade=0, remove=0, rebuild=0)
    for name, record in links.items():
        if name not in before:
            counts['install'] += 1
        elif version(record['version']) > version(before[name]['version']):
            counts['upgrade'] += 1
        elif version(record['version']) < version(before[name]['version']):
            counts['downgrade'] += 1
        else:
            counts['rebuild'] += 1
    counts['remove'] = len(set(unlinks) - set(links))
    for key in ['install', 'upgrade', 'downgrade', 'remove', 'rebuild']:
        print('Packages to {:9}: {}'.format(key, counts[key]))
    fetch = actions.get('FETCH')
    counts['download_bytes'] = sum(r.get('size', 0) or 0 for r in fetch) if fetch is not None else None
    print('Download size         : ' + ('{:.1f} MiB'.format(counts['download_bytes'] / 1048576) if counts['download_bytes'] is not None else 'not provided by solver'))
    return counts

@contextlib.contextmanager
def locked(root, reuse=False):
    key = (os.getpid(), threading.get_ident(), str(Path(root).absolute()))
    if reuse and key in _HELD_LOCKS:
        yield
        return
    path = Path(root) / '.science-installer.lock'
    safety.plain_path(path, missing=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(fd, 'a+b') as stream:
        if os.name == 'nt':
            import msvcrt
            stream.seek(0)
            if os.fstat(stream.fileno()).st_size == 0:
                stream.write(b'\0'); stream.flush()
            stream.seek(0)
            try:
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as exc:
                raise OperationBlocked('BLOCKED: another installation/removal holds the live kernel lock. Wait for it to finish, then Recheck. A leftover unlocked lock file is reused safely; do not delete a live lock.') from exc
            _HELD_LOCKS.add(key)
            try:
                yield
            finally:
                _HELD_LOCKS.discard(key)
                stream.seek(0); msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                raise OperationBlocked('BLOCKED: another installation/removal holds the live kernel lock. Wait for it to finish, then Recheck. A leftover unlocked lock file is reused safely; do not delete a live lock.') from exc
            _HELD_LOCKS.add(key)
            try:
                yield
            finally:
                _HELD_LOCKS.discard(key)
                fcntl.flock(stream, fcntl.LOCK_UN)


def platform_guard():
    if sys.platform != 'linux' or os.uname().machine != 'x86_64':
        raise InstallError('Ubuntu x86-64 is required for installation.')
    import platform
    os_release = platform.freedesktop_os_release()
    if os_release.get('ID') != 'ubuntu' or os_release.get('VERSION_ID') not in ['24.04', '26.04']:
        raise InstallError('Only Ubuntu 24.04/26.04 LTS is supported.')
    if not os.environ.get('USER', '').isascii() or not os.environ.get('USER'):
        raise InstallError('ASCII usernames are required.')


def bootstrap(root, config, home=None, fetch=None):
    root = guard_root(root, home, allow_new=True)
    if root.exists() and using_science(root / 'envs/science'):
        raise InstallError('Close/deactivate science before installation/update.')
    created_root = not root.exists()
    if created_root:
        root.mkdir(parents=True)
        atomic_bytes(root / '.scientific-python-installer-state',
                     (MARKER + '\ninstaller_version=' + config['InstallerVersion'] + '\nstatus=prepared\nlayout=home\nroot_owned=true\n').encode(), 0o600)
    if created_root:
        write_json(root / '.science-root-owner.json', {'managed_by': 'scientific-python-ubuntu', 'scope': 'micromamba-binary',
            'root': str(root), 'executable': str(root / 'bin/micromamba'), 'sha256': config['MicromambaExeSha256'],
            'created_root_identity': [root.stat().st_dev, root.stat().st_ino]})
    (root / 'tmp').mkdir(exist_ok=True)
    (root / 'bin').mkdir(exist_ok=True)
    mm = root / 'bin/micromamba'
    if mm.is_symlink():
        raise InstallError('Refusing to replace a symlinked executable.')
    if mm.is_file() and hashlib.sha256(mm.read_bytes()).hexdigest() == config['MicromambaExeSha256']:
        return False
    url = 'https://github.com/mamba-org/micromamba-releases/releases/download/' + config['MicromambaRelease'] + '/' + config['MicromambaArchive']
    with tempfile.TemporaryDirectory(prefix='bootstrap-', dir=root / 'tmp') as tmp:
        archive = Path(tmp) / 'micromamba.tar.bz2'
        if fetch:
            fetch(url, archive)
        else:
            with urllib.request.urlopen(url, timeout=120) as response, archive.open('wb') as out:
                shutil.copyfileobj(response, out)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != config['MicromambaArchiveSha256']:
            raise InstallError('Micromamba archive SHA256 mismatch.')
        with tarfile.open(archive, 'r:bz2') as tar:
            member = tar.getmember('bin/micromamba')
            if not member.isfile():
                raise InstallError('Unexpected Micromamba archive member.')
            content = tar.extractfile(member).read()
        if hashlib.sha256(content).hexdigest() != config['MicromambaExeSha256']:
            raise InstallError('Micromamba executable SHA256 mismatch.')
        if mm.exists():
            raise InstallError('Existing Micromamba executable differs; it will not be replaced automatically.')
        atomic_bytes(mm, content, 0o755)
    return True


def run_process(argv, env=None, timeout=1800):
    return subprocess.run([str(a) for a in argv], env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='replace', timeout=timeout)


def parse_plan(output):
    for i, char in enumerate(output):
        if char == '{':
            try:
                value, _ = json.JSONDecoder().raw_decode(output[i:])
                if isinstance(value, dict) and 'success' in value:
                    return value
            except ValueError:
                pass
    raise InstallError('Micromamba did not return transaction JSON.')


def public_record(record):
    return {key: record.get(key) for key in ['name', 'version', 'build', 'build_string', 'subdir', 'sha256']}


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def package_fingerprint(installed):
    return fingerprint([public_record(r) for r in sorted(installed.values(), key=lambda r: r['name'])])


def isolated_env(root, mm, home=None):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('CONDA_', 'MAMBA_', 'SPYDER_')) or key in ['PYTHONHOME', 'PYTHONPATH']:
            env.pop(key, None)
    env.update(MAMBA_ROOT_PREFIX=str(root), MAMBA_EXE=str(mm), CONDA_EXE=str(mm),
               CONDA_PKGS_DIRS=str(Path(root) / 'pkgs'), TMPDIR=str(Path(root) / 'tmp'))
    if home is not None: env['HOME'] = str(home)
    return env


def restore_approved_metadata(lock, prefix):
    # @EXPLICIT carries identity/checksum, not channel dependency/hotfix metadata.
    # Keep native file/link records, restore the approved repodata for linked pkgs.
    linked = {r['name']: r for r in lock['approved_plan'].get('actions', {}).get('LINK', [])}
    fields = ['fn', 'url', 'channel', 'depends', 'constrains', 'noarch', 'build_number', 'license', 'size', 'md5', 'timestamp', 'track_features']
    restored = 0
    for path in (prefix / 'conda-meta').glob('*.json'):
        actual = safety.json_regular(path)
        approved = linked.get(actual.get('name'))
        if approved is None: continue
        if tx.identity(actual) != tx.identity(approved):
            raise InstallError('Cannot restore metadata for an unexpected package: ' + str(actual.get('name')))
        updated = dict(actual)
        for field in fields:
            if field in approved:
                value = approved[field]
                if field in ['depends', 'constrains'] and value is None: value = []
                if field == 'noarch' and value is None: updated.pop(field, None)
                else: updated[field] = value
        if updated != actual:
            atomic_bytes(path, (json.dumps(updated, indent=2) + '\n').encode()); restored += 1
    return restored


def has_nvidia_device(runner=None, env=None):
    nvidia_smi = shutil.which('nvidia-smi')
    if not nvidia_smi:
        return False
    try:
        devices = (runner or run_process)([nvidia_smi, '-L'], env=env, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return False
    return devices.returncode == 0 and bool(re.search(r'^GPU \d+:', devices.stdout, re.MULTILINE))


def cuda_solver_settings(mm, root, runner, env):
    nvidia_smi = shutil.which('nvidia-smi')
    if not nvidia_smi:
        raise InstallError('PyTorch CUDA requires nvidia-smi and a working NVIDIA driver.')
    driver = runner([nvidia_smi, '--query', '-u', '-x'], env=env, timeout=15)
    devices = runner([nvidia_smi, '--query-gpu=compute_cap', '--format=csv,noheader'], env=env, timeout=15)
    versions = re.findall(r'<cuda_version>\s*([1-9]\d*\.\d+)\s*</cuda_version>', driver.stdout)
    releases = re.findall(r'<driver_version>\s*([1-9]\d*(?:\.\d+){1,3})\s*</driver_version>', driver.stdout)
    capabilities = devices.stdout.strip().splitlines()
    if (driver.returncode or devices.returncode or len(versions) != 1 or len(releases) != 1 or not capabilities or
            any(not re.fullmatch(r'[1-9]\d*\.\d+', item.strip()) for item in capabilities)):
        raise InstallError('The NVIDIA driver capability and GPU compute capability could not be verified.')
    driver_version = versions[0]
    gpu_arch = min((item.strip() for item in capabilities), key=version)

    def virtual_packages(overrides):
        info = runner([mm, 'info', '--no-rc', '-r', root, '--json'], env=env | overrides, timeout=30)
        if info.returncode:
            raise InstallError('Could not verify CUDA compatibility in Micromamba.')
        rows = json.loads(info.stdout).get('virtual packages', [])
        result = {}
        for row in rows:
            match = re.fullmatch(r'(__cuda|__cuda_arch)=([1-9]\d*\.\d+)=0', row)
            if match:
                if match[1] in result:
                    raise InstallError('Micromamba reported ambiguous CUDA virtual packages.')
                result[match[1]] = match[2]
        return result

    native = virtual_packages({})
    overrides = {}
    if native.get('__cuda') != driver_version:
        overrides['CONDA_OVERRIDE_CUDA'] = driver_version
    if native.get('__cuda_arch') != gpu_arch:
        if '__cuda_arch' in native:
            raise InstallError('Micromamba GPU architecture disagrees with the detected hardware.')
        overrides['CONDA_OVERRIDE_CUDA_ARCH'] = gpu_arch
    if overrides:
        verified = virtual_packages(overrides)
        if verified.get('__cuda') != driver_version:
            raise InstallError('Micromamba could not verify the NVIDIA driver CUDA capability.')
        if '__cuda_arch' not in verified:
            overrides.pop('CONDA_OVERRIDE_CUDA_ARCH', None)
            print('Micromamba lacks __cuda_arch. The selected cuda-arch package minimum will be checked against the GPU.',
                  flush=True)
        elif verified['__cuda_arch'] != gpu_arch:
            raise InstallError('Micromamba returned a CUDA architecture different from the verified hardware.')
    major, minor = map(int, driver_version.split('.'))
    print(f'NVIDIA driver CUDA {driver_version}; minimum detected GPU compute capability {gpu_arch}.', flush=True)
    if overrides:
        print('Using verified hardware values in Micromamba subprocesses: ' +
              ', '.join(f'{key}={value}' for key, value in overrides.items()), flush=True)
    # NVIDIA documents CUDA 13 minor compatibility for R580 and newer.
    minor_limit = '14' if major == 13 and version(releases[0])[0] >= 580 else None
    return {'driver': driver_version, 'architecture': gpu_arch, 'runtime_limit': f'{major}.{minor + 1}',
            'minor_limit': minor_limit, 'overrides': overrides}


def assert_cuda_solution(after, settings):
    runtime = after.get('cuda-version', {})
    toolkit = runtime.get('version')
    minimum = after.get('cuda-arch', {}).get('version')
    if not minimum or version(minimum) > version(settings['architecture']):
        raise InstallError('The planned CUDA packages lack a verified compatible GPU compute capability.')
    if not toolkit:
        raise InstallError('The planned CUDA packages lack a runtime version record.')
    if version(toolkit) < version(settings['runtime_limit']):
        return False
    if (not settings['minor_limit'] or version(toolkit) >= version(settings['minor_limit']) or
            not re.fullmatch(r'https://conda\.anaconda\.org/conda-forge/(?:linux-64|noarch)/cuda-version-[^/?#]+',
                             runtime.get('url', '')) or '__cuda >=13' not in runtime.get('constrains', [])):
        raise InstallError('The planned CUDA runtime exceeds the verified driver capability.')
    return True


def cuda_runtime_conflict(result):
    try:
        problems = json.loads(result.stdout).get('solver_problems', [])
    except (ValueError, AttributeError):
        return False
    return any(re.search(r'\bcuda-version\b', str(problem)) for problem in problems)


def sync(root, config, runner=run_process, home=None, mm=None, existing=False, reviewer=None, progress=None, fetch=None):
    root = guard_root(root, home, existing=existing)
    guard_science(root)
    if not read_state(root) and not owned_science(root):
        reserved = ['.science-attempt.json', '.science-update-plan.json', 'science-packages.json', 'science-runtime.json', 'science-diagnostics.json', '.science-launchers.json']
        if any((root / name).exists() for name in reserved):
            raise InstallError('Unmanaged files occupy installer report paths; no files were replaced.')
    prefix = root / 'envs/science'
    if using_science(prefix):
        raise_busy(prefix, 'updated')
    mm = Path(mm) if mm else root / 'bin/micromamba'
    (root / 'tmp').mkdir(exist_ok=True)
    env = isolated_env(root, mm)
    # Explicit root/cache isolation also applies to download and offline passes.
    env = env.copy()
    env.update(MAMBA_ROOT_PREFIX=str(root), MAMBA_EXE=str(mm), CONDA_PKGS_DIRS=str(root / 'pkgs'), TMPDIR=str(root / 'tmp'))
    env.pop('SPYDER_DEBUG', None); env.pop('SPYDER_DEBUG_FILE', None)
    with locked(root, reuse=True):
        before = records(prefix)
        if before: safety.read_regular(prefix / 'conda-meta/history')
        previous_requests = history_specs(prefix)
        intent = (set(before) if previous_requests is None else previous_requests) | {spec_name(s) for s in specs(config)}
        requested = specs(config, before)
        torch_backend = science_config.pytorch_backend(requested)
        cuda = None
        cuda_retry = None
        if torch_backend == 'cuda':
            cuda = cuda_solver_settings(mm, root, runner, env)
            env.update(cuda['overrides'])
            if not any(spec_name(spec) == 'cuda-version' for spec in requested):
                requested.append('cuda-version<' + cuda['runtime_limit'])
                if cuda['minor_limit']:
                    cuda_retry = 'cuda-version<' + cuda['minor_limit']
        if torch_backend in ('cpu', 'cuda'):
            print('PyTorch backend requested: ' + torch_backend.upper() + '.', flush=True)
        command = 'update' if before else 'create'
        argv = [mm, command, '--no-rc', '-r', root, '-p', prefix, '--override-channels', *[arg for channel in config['Channels'] for arg in ['-c', channel]],
                '--strict-channel-priority', '--no-pyc', '--json']
        if command == 'update':
            argv += ['--all']
        argv += requested
        write_json(root / '.science-attempt.json', {'status': 'preflight', 'package_changes_started': False})
        result = runner(argv + ['--dry-run'], env=env)
        if result.returncode and cuda_retry and cuda_runtime_conflict(result):
            print('Checking CUDA 13 minor-version compatibility with the same scientific package constraints.', flush=True)
            result = runner(argv[:-1] + [cuda_retry, '--dry-run'], env=env)
        if result.returncode:
            write_json(root / '.science-attempt.json', {'status': 'preflight_failed', 'exit_code': result.returncode, 'package_changes_started': False})
            print(result.stdout, end=''); print(result.stderr, file=sys.stderr, end='')
            if torch_backend == 'cuda' and '__cuda_arch' in (result.stdout + result.stderr):
                raise InstallError('Micromamba could not satisfy __cuda_arch for the available packages. Use a verified Micromamba release with CEP 46 support or a compatible conda-forge CUDA build. No package changes started.')
            raise InstallError('Dependency solve failed before package changes. Incompatible extra packages or version pins must be resolved; OpenCV/FFmpeg limits are unchanged.')
        if result.stderr: print(result.stderr, file=sys.stderr, end='')
        plan = parse_plan(result.stdout)
        after = check_plan(plan, before, config, history_specs(prefix))
        if cuda:
            minor_compatibility = assert_cuda_solution(after, cuda)
            plan['cuda_compatibility'] = {'driver': cuda['driver'], 'gpu_compute_capability': cuda['architecture'],
                                          'runtime': after['cuda-version']['version'],
                                          'minimum_compute_capability': after['cuda-arch']['version'],
                                          'minor_version_compatibility': minor_compatibility}
            if minor_compatibility:
                print(f"CUDA {after['cuda-version']['version']} uses NVIDIA minor-version compatibility with "
                      f"driver CUDA {cuda['driver']}. New driver features and PTX JIT can require a newer driver. "
                      "Review this limitation before approving; GPU execution is checked after installation.", flush=True)
        actions = plan.get('actions') or {}
        tx.indexed(after.values())
        changes = {key: [public_record(r) for r in actions.get(key, [])] for key in ['LINK', 'UNLINK']}
        counts = plan_summary(plan, before)
        write_json(root / '.science-update-plan.json', {'status': 'validated', 'changes': changes, 'counts': counts, 'plan': plan})
        if progress: progress(4, 'PASS')
        print('Validated plan: {} links, {} unlinks.'.format(len(changes['LINK']), len(changes['UNLINK'])), flush=True)
        print('Full plan: ' + str(root / '.science-update-plan.json'), flush=True)
        for name in ['python', 'spyder', 'opencv', 'ffmpeg', 'apache-arrow-proc']:
            old = before.get(name, {}).get('version', 'not installed')
            new = after[name]
            print('{}: {} -> {} ({})'.format(name, old, new['version'], new.get('build', new.get('build_string'))), flush=True)
        if torch_backend in ('cpu', 'cuda'):
            torch = after['pytorch']
            print('PyTorch {}: {} ({})'.format(torch_backend.upper(), torch['version'],
                  torch.get('build', torch.get('build_string'))), flush=True)
        removed = {r['name'] for r in changes['UNLINK']} - {r['name'] for r in changes['LINK']}
        if removed:
            print('Obsolete dependency removals in the validated plan: ' + ', '.join(sorted(removed)), flush=True)
        if not changes['LINK'] and not changes['UNLINK']:
            print('Already up to date: no package transaction is necessary.')
            if progress: progress(5, 'PASS'); progress(6, 'SKIP')
            write_json(root / '.science-attempt.json', {'status': 'packages_already_current', 'package_changes_started': False})
            return False
        if progress: progress(5, 'RUNNING')
        if not (reviewer or approve_plan)(plan, before, after):
            write_json(root / '.science-attempt.json', {'status': 'cancelled', 'package_changes_started': False})
            raise InstallError('Package changes were not approved.')
        if progress: progress(5, 'PASS'); progress(6, 'RUNNING')
        # The accepted online solution is the only authority after approval.
        # Download-only and offline do not receive free version specifications.
        guard_root(root, home, existing=existing)
        guard_science(root)
        lock = tx.freeze(before, plan, prefix)
        transaction_base = root / '.science-transactions'
        safety.plain_path(transaction_base, missing=True)
        marker = transaction_base / '.owner.json'
        expected_owner = {'managed_by': 'scientific-python-ubuntu', 'root': str(root), 'scope': 'locked-transactions'}
        if transaction_base.exists():
            if safety.json_regular(marker) != expected_owner:
                raise InstallError('Unmanaged transaction directory will not be overwritten.')
        else:
            transaction_base.mkdir(); write_json(marker, expected_owner)
        directory = transaction_base / tx.digest(lock)
        safety.plain_path(directory, missing=True); directory.mkdir(exist_ok=True)
        lock_path = directory / 'approved-lock.json'
        if lock_path.exists() and safety.json_regular(lock_path) != lock:
            raise InstallError('Existing approved lock changed; refusing transaction.')
        write_json(lock_path, lock)
        write_json(root / '.science-update-plan.json', {'status': 'approved_locked', 'changes': changes, 'counts': counts,
                   'plan': plan, 'lock_file': str(lock_path), 'lock_sha256': hashlib.sha256(lock_path.read_bytes()).hexdigest(),
                   'identity_fields': list(tx.FIELDS)})
        locked_env = env.copy(); locked_env.update(CONDA_PKGS_DIRS=str(directory / 'cache'), MAMBA_SAFETY_CHECKS='enabled', MAMBA_EXTRA_SAFETY_CHECKS='true')
        package_changes_started = False
        def check_state():
            guard_root(root, home, existing=existing)
            guard_science(root)
            tx.assert_installed(lock['before'], records(prefix).values())
        claim = {'managed_by': 'scientific-python-ubuntu', 'scope': 'science-environment', 'root': str(root),
                 'prefix': str(prefix), 'micromamba_exe': str(mm), 'phase': 'download',
                 'prefix_identity': [prefix.stat().st_dev, prefix.stat().st_ino] if prefix.exists() else None}
        def prepare_prefix():
            check_state()
            prefix.mkdir(parents=True, exist_ok=True)
            info = prefix.stat()
            claim['prefix_identity'] = [info.st_dev, info.st_ino]
            (prefix / 'conda-meta').mkdir(exist_ok=True)
            safety.plain_path(prefix / 'conda-meta/history', missing=True)
            if not (prefix / 'conda-meta/history').exists(): (prefix / 'conda-meta/history').touch()
            write_json(prefix / '.science-owner.json', {'managed_by': 'scientific-python-ubuntu', 'root': str(root)})
            write_json(root / '.science-env-owner.json', claim)
        def before_commit():
            nonlocal package_changes_started
            check_state()
            if using_science(prefix): raise_busy(prefix, 'updated')
            claim.update(phase='transaction', prefix_identity=[prefix.stat().st_dev, prefix.stat().st_ino])
            write_json(root / '.science-env-owner.json', claim)
            write_json(prefix / '.science-owner.json', {'managed_by': 'scientific-python-ubuntu', 'root': str(root)})
            package_changes_started = True
            write_json(root / '.science-attempt.json', {'status': 'locked_transaction', 'package_changes_started': True,
                       'lock_file': str(lock_path), 'lock_sha256': hashlib.sha256(lock_path.read_bytes()).hexdigest()})
        try:
            write_json(root / '.science-attempt.json', {'status': 'staging_approved_archives', 'package_changes_started': False,
                       'lock_file': str(lock_path)})
            tx.stage_archives(lock, directory, root / 'pkgs', safety.plain_path, fetch=fetch)
            tx.apply(lock, directory, mm, root, locked_env, runner, parse_plan, check_state,
                     before_commit, write_json, safety.plain_path, prepare_prefix)
            tx.assert_installed(lock['after'], records(prefix).values())
            metadata_restored = restore_approved_metadata(lock, prefix)
            write_json(directory / 'metadata-restoration.json', {'restored_records': metadata_restored, 'source': 'approved online repodata'})
            tx.assert_installed(lock['after'], records(prefix).values())
        except (InstallError, OSError, ValueError, subprocess.SubprocessError) as exc:
            write_json(root / '.science-attempt.json', {'status': 'locked_transaction_failed' if package_changes_started else 'locked_preflight_failed',
                       'package_changes_started': package_changes_started, 'error': str(exc),
                       'package_differences': getattr(exc, 'differences', {}), 'rollback_reported': getattr(exc, 'rollback_reported', False), 'lock_file': str(lock_path)})
            raise
        # create may recreate the prefix and discard its pre-transaction marker.
        # Reattach ownership only after a reported successful transaction and a
        # fresh no-redirection guard, never after an ambiguous failed transaction.
        guard_root(root, home, existing=existing)
        write_json(prefix / '.science-owner.json', {'managed_by': 'scientific-python-ubuntu', 'root': str(root)})
        installed = records(prefix)
        check_plan({'success': True}, installed, config, history_specs(prefix))
        # Compare with pre-update media versions as well, even if records were replaced.
        for name in ['opencv', 'ffmpeg']:
            if name in before and version(installed[name]['version']) < version(before[name]['version']):
                raise InstallError('Unexpected installed media downgrade.')
        # Explicit mechanics list every dependency. Preserve the original user
        # intent separately so dependencies do not become protected user extras.
        history = prefix / 'conda-meta/history'
        history_bytes = safety.read_regular(history)[0]
        annotation = ('\n# scientific-python requested specs: ' + repr(sorted(intent)) + '\n').encode()
        atomic_bytes(history, history_bytes + annotation)
        write_json(root / 'science-packages.json', [public_record(r) for r in sorted(installed.values(), key=lambda r: r['name'])])
        claim.update(phase='installed', prefix_identity=[prefix.stat().st_dev, prefix.stat().st_ino])
        write_json(root / '.science-env-owner.json', claim)
        write_json(root / '.science-attempt.json', {'status': 'packages_updated', 'package_changes_started': True})
        if progress: progress(6, 'PASS')
        return True


def strip_blocks(content, begin, end):
    lines = content.splitlines(keepends=True)
    output = []; skipping = False
    for line in lines:
        marker = line.rstrip(b'\r\n')
        if marker == begin:
            if skipping:
                raise InstallError('Nested managed Bash block; profile unchanged.')
            skipping = True
        elif marker == end:
            if not skipping:
                raise InstallError('Unmatched managed Bash marker; profile unchanged.')
            skipping = False
        elif not skipping:
            output.append(line)
    if skipping:
        raise InstallError('Unclosed managed Bash block; profile unchanged.')
    return b''.join(output)


def profile(root, home=None, remove=False):
    home = Path(home) if home is not None else Path.home()
    guard_root(root, home, existing=True)
    bashrc = home / '.bashrc'
    old = bashrc.read_bytes() if bashrc.exists() else b''
    new = strip_blocks(old, PATH_BEGIN, PATH_END)
    if not remove:
        # Add only a command search path. No shell init, activation or root exports.
        block = (PATH_BEGIN + b'\n# Managed Scientific Python command path; activation is unchanged.\n'
                 b'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n' + PATH_END + b'\n')
        new = new.rstrip(b'\r\n') + b'\n\n' + block if new else block
    if new != old:
        atomic_bytes(bashrc.resolve() if bashrc.is_symlink() else bashrc, new, None if bashrc.exists() else 0o644)

def desktop_exec(path):
    value = str(path)
    if '\n' in value or '\r' in value:
        raise InstallError('Invalid desktop launcher path.')
    value = value.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')
    # Desktop string unescaping precedes Exec argument unquoting. Preserve the
    # Exec-level backslashes through both layers (freedesktop Exec section 7).
    value = value.replace('\\', '\\\\')
    return '"' + value + '" %F'


def spyder_profile_hook(root, support, active):
    # Micromamba runs deactivate.d with the outgoing CONDA_SHLVL. Popping a
    # stacked environment can re-run activate.d for an already saved level.
    header = '# Scientific Python managed Spyder profile ' + fingerprint(str(root)) + '\n'
    slot = '_SCIENCE_SPYDER_' + fingerprint(str(root))[:16] + '_'
    body = """
case ${CONDA_SHLVL:-} in
    ''|*[!0-9]*) printf 'Invalid science activation level.\\n' >&2; return 1 ;;
esac
_science_slot=@SLOT@${CONDA_SHLVL}
"""
    # Export each frame so a child Bash can deactivate an inherited science.
    if active:
        body += """
_science_state=${_science_slot}_set
if [[ ! -v $_science_state ]]; then
    export "${_science_state}=${SPYDER_CONFDIR+x}" "${_science_slot}_value=${SPYDER_CONFDIR-}"
fi
if ! _science_profile=$(/usr/bin/python3 -I -B @MANAGER@ spyder-profile --root @ROOT@); then
    # Some activation drivers continue after a failed sourced hook. Prevent a
    # subsequent plain Spyder from silently opening the previous/shared profile.
    export SPYDER_CONFDIR=/dev/null/science-spyder-profile-unavailable
    unset _science_profile _science_slot _science_state
    return 1
fi
export SPYDER_CONFDIR="$_science_profile"
unset _science_profile _science_state
"""
    else:
        body += """
_science_state=${_science_slot}_set
_science_value=${_science_slot}_value
case ${!_science_state-missing} in
    x) export SPYDER_CONFDIR="${!_science_value}" ;;
    '') unset SPYDER_CONFDIR ;;
esac
unset "$_science_state" "$_science_value" _science_state _science_value
"""
    body = body.replace('@SLOT@', slot).replace('@MANAGER@', shlex.quote(str(support / 'science-manager.py')))
    return header + '[ -n "${BASH_VERSION:-}" ] || return 0\n' + body.replace('@ROOT@', shlex.quote(str(root))) + 'unset _science_slot\n'


def prepare_spyder_profile(root, home=None):
    # Spyder 6 stores the two switches in spyder.ini and the path in
    # transient.ini. Touch only those options, in the existing owned profile.
    root = guard_root(root, home, existing=True)
    if not owned_science(root) or not (root / 'envs/science').is_dir():
        raise InstallError('An owned science environment is required for Spyder settings.')
    profile = prepare_settings(root, home)
    updates = []
    for name, options in [('spyder.ini', {'default': 'True', 'custom': 'False'}),
                          ('transient.ini', {'executable': str(root / 'envs/science/bin/python')})]:
        path = safety.plain_path(profile / 'config' / name, missing=True)
        config = configparser.RawConfigParser()
        if path.exists():
            config.read_string(safety.read_regular(path)[0].decode('utf-8'))
        if not config.has_section('main_interpreter'):
            config.add_section('main_interpreter')
        section = config['main_interpreter']
        if any(section.get(key) != value for key, value in options.items()):
            section.update(options)
            output = io.StringIO()
            config.write(output)
            updates.append((path, output.getvalue().encode('utf-8')))
    for path, content in updates:
        atomic_bytes(path, content, 0o600)
    return profile


def artifacts(root, directory=BUNDLE, home=None, mm=None, desktop_shortcut=None):
    home = Path(home) if home is not None else Path.home()
    root = guard_root(root, home, existing=True)
    mm = Path(mm) if mm else root / 'bin/micromamba'
    launcher = home / '.local/bin/science-spyder'
    desktop = home / '.local/share/applications/scientific-python-spyder.desktop'
    targets = [(launcher, b'# Scientific Python managed Spyder launcher'), (desktop, b'X-Scientific-Python-Managed=true')]
    if desktop_shortcut: targets.append((Path(desktop_shortcut), b'X-Scientific-Python-Managed=true'))
    root_id = fingerprint(str(root))
    for path, marker in targets:
        safety.plain_path(path, missing=True)
        if path.is_symlink() or (path.exists() and marker not in path.read_bytes()):
            raise InstallError('A foreign or symlinked launcher exists: ' + str(path))
        if path == launcher and path.exists() and ('# Scientific-Python-Root-Id: ' + root_id + '\n').encode() not in path.read_bytes() and str(root).encode() not in path.read_bytes():
            raise InstallError('A managed command launcher belongs to another root.')
        if path.exists() and b'X-Scientific-Python-Root-Id=' in path.read_bytes() and ('X-Scientific-Python-Root-Id=' + root_id + '\n').encode() not in path.read_bytes():
            raise InstallError('A launcher belongs to another root: ' + str(path))
    support = root / 'share/scientific-python'
    if support.is_symlink(): raise InstallError('Symlinked support directory refused.')
    if support.exists() and not (support / 'science-release.json').is_file():
        raise InstallError('Unmanaged support directory will not be overwritten.')
    prefix = root / 'envs/science'
    hooks = []
    if prefix.exists():
        guard_science(root)
        for active, group in [(True, 'activate.d'), (False, 'deactivate.d')]:
            hook = prefix / 'etc/conda' / group / 'scientific-python-spyder.sh'
            content = spyder_profile_hook(root, support, active).encode()
            safety.plain_path(hook, missing=True)
            if hook.exists() and safety.read_regular(hook)[0] != content:
                raise InstallError('Foreign or edited Spyder activation hook is preserved: ' + str(hook))
            hooks.append((hook, content))
        prepare_spyder_profile(root, home)
    # Replicate the immutable platform bundle and its shared resources for subsequent diagnostics.
    for line in (Path(directory) / 'SHA256SUMS.txt').read_text().splitlines():
        _, name = line.split('  ', 1)
        source = science_config.shared(directory) / name[7:] if name.startswith('shared/') else Path(directory) / name
        atomic_bytes(support / name, source.read_bytes(), 0o644)
    atomic_bytes(support / 'SHA256SUMS.txt', (Path(directory) / 'SHA256SUMS.txt').read_bytes(), 0o644)
    snapshot = support / 'science-release.json'
    current = science_config.active_path().read_bytes()
    if snapshot.exists() and snapshot.read_bytes() != current:
        digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
        backup = support / ('science-release.previous-' + digest + '.json')
        if not backup.exists(): atomic_bytes(backup, snapshot.read_bytes(), 0o600)
    atomic_bytes(snapshot, current, 0o600)
    wrapper = (Path(directory) / 'spyder-launcher.sh').read_text().replace('@ROOT@', shlex.quote(str(root))).replace('@MM@', shlex.quote(str(mm))).replace('@ROOT_ID@', root_id)
    atomic_bytes(launcher, wrapper.encode(), 0o755)
    content = ('[Desktop Entry]\nVersion=1.0\nType=Application\nName=Scientific Python - Spyder\nComment=Spyder IDE in the science environment\n'
               'Exec=' + desktop_exec(launcher) + '\nTerminal=false\nCategories=Development;IDE;Science;\nStartupNotify=true\n'
               'Keywords=Python;Spyder;Science;IPython;\nIcon=applications-development\nX-Scientific-Python-Managed=true\n'
               'X-Scientific-Python-Root-Id=' + root_id + '\nX-Scientific-Python-Root=' + str(root).replace('\\', '\\\\') + '\n')
    desktop_tools.write_entry(desktop, content.encode(), 0o644, atomic_bytes)
    if desktop_shortcut: desktop_tools.write_entry(desktop_shortcut, content.encode(), 0o755, atomic_bytes)
    if not prefix.exists(): return desktop
    for hook, content in hooks:
        atomic_bytes(hook, content, 0o644)
    for active, group in [(True, 'activate.d'), (False, 'deactivate.d')]:
        target = prefix / 'etc/conda' / group / 'scientific-python-usage.sh'
        safety.plain_path(target, missing=True)
        if target.exists() and not safety.read_regular(target)[0].startswith(b'# Scientific Python science activation tracking'):
            raise InstallError('Foreign activation tracking hook is preserved.')
        atomic_bytes(target, processes.hook_text(prefix, support, active).encode(), 0o644)
    return desktop

def verify_bundle(directory=BUNDLE):
    try: return science_integrity.verify(directory)
    except (ValueError, OSError) as exc: raise InstallError(str(exc)) from exc


def diagnostics(root, output):
    root = Path(root); output = Path(output)
    installed = records(root / 'envs/science')
    report = {'schema': 4, 'collection_status': 'SUCCESS', 'report_exit': 0,
              'platform': sys.platform, 'environment_present': bool(installed),
              'packages': [public_record(r) for r in sorted(installed.values(), key=lambda r: r['name'])]}
    try:
        check_plan({'success': True}, installed, release())
        report['v4_package_policy'] = {'status': 'PASS'}
    except InstallError as exc:
        report['v4_package_policy'] = {'status': 'FAIL', 'reason': str(exc)}
    for name in ['.science-attempt.json', '.science-update-plan.json', 'science-runtime.json', 'science-launch-context.json', 'science-spyder-kernel.json', 'science-spyder-startup.json', 'science-fontconfig-repair.json', 'science-removal.json', 'science-other-environments.json']:
        path = root / name
        if path.is_file():
            report[name] = json.loads(path.read_text(encoding='utf-8'))
    write_json(output, report)
    return report


def mark_complete(root, config, home=None, mm=None, mode=None, micromamba_version=None):
    root = guard_root(root, home, existing=True)
    installed = records(root / 'envs/science')
    check_plan({'success': True}, installed, config)
    content = (MARKER + '\ninstaller_version=' + config['InstallerVersion'] +
               '\nmicromamba_version=' + (micromamba_version or read_state(root).get('micromamba_version', 'unknown')) + '\npython_spec=' + config['Python'] +
               '\nspyder_spec=' + config['Spyder'] + '\nstatus=complete\nlayout=selected\nroot=' + str(root) +
               '\nscience=' + str(root / 'envs/science') + '\n')
    previous = read_state(root)
    mode = mode or previous.get('mode', 'Recommended')
    content += 'mode=' + mode.lower() + '\nroot_owned=' + previous.get('root_owned', 'true' if mode.lower() != 'existing' else 'false') + '\n'
    content += 'micromamba_exe=' + str(mm or root / 'bin/micromamba') + '\n'
    write_json(root / 'envs/science/.science-owner.json', {'managed_by': 'scientific-python-ubuntu', 'root': str(root)})
    content += 'release_fingerprint=' + fingerprint(config) + '\npackage_fingerprint=' + package_fingerprint(installed) + '\n'
    atomic_bytes(root / '.scientific-python-installer-state', content.encode(), 0o600)


def launcher_removal_plan(root, home=None):
    home = Path(home) if home is not None else Path.home()
    root = Path(root)
    safety.plain_path(home)
    safety.plain_path(root, missing=True)
    standard = {root / 'bin/science-spyder', home / '.local/bin/science-spyder',
                home / '.local/share/applications/scientific-python-spyder.desktop'}
    paths = set(standard)
    manifest = root / '.science-launchers.json'
    if os.path.lexists(manifest):
        value = safety.json_regular(manifest)
        if not isinstance(value.get('paths'), list) or not all(isinstance(item, str) for item in value['paths']):
            raise InstallError('Invalid launcher manifest; nothing was removed.')
        for item in value['paths']:
            target = Path(item)
            if target not in standard:
                if target.name != 'scientific-python-spyder.desktop' or not target.is_absolute():
                    raise InstallError('Launcher manifest escapes the known launcher locations.')
                if not shutil.which('xdg-user-dir'):
                    raise InstallError('Desktop shortcut location cannot be confirmed.')
                env = os.environ.copy(); env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'))
                result = run_process(['xdg-user-dir', 'DESKTOP'], env=env, timeout=10)
                desktop = Path(result.stdout.strip())
                if result.returncode or desktop == home or not desktop.is_absolute() or target.parent != desktop:
                    raise InstallError('Desktop shortcut is outside the current XDG desktop directory.')
            paths.add(target)
    plans = []
    root_id = fingerprint(str(root))
    state = read_state(root) if root.exists() else {}
    legacy = state.get('managed_by') == 'scientific-python-ubuntu' and root == home / 'micromamba'
    for target in sorted(paths):
        safety.plain_path(target, missing=True)
        if not target.exists(): continue
        content = safety.read_regular(target)[0]
        lines = content.splitlines()
        wrapper = b'# Scientific Python managed Spyder launcher' in lines
        desktop = b'X-Scientific-Python-Managed=true' in lines
        identified = ((('# Scientific-Python-Root-Id: ' + root_id).encode() in lines and wrapper) or
                      (('X-Scientific-Python-Root-Id=' + root_id).encode() in lines and desktop))
        legacy_identified = legacy and ((target == root / 'bin/science-spyder' and wrapper and b'ROOT="$HOME/micromamba"' in lines) or
            (desktop and ('Exec=' + desktop_exec(root / 'bin/science-spyder')).encode() in lines))
        if identified or legacy_identified: plans.append(safety.file_plan(target))
    return plans


def clean_launchers(root, home=None):
    plans = launcher_removal_plan(root, home)
    for plan in plans: safety.check_file(plan)
    for plan in plans: safety.unlink_file(plan)

def using_science(prefix):
    return processes.inspect(prefix)['status'] == 'BLOCKED'


def removal_ownership(root):
    root = Path(root)
    guard_science(root)
    receipt = root / '.science-env-owner.json'
    if os.path.lexists(receipt) and ownership_json(receipt).get('phase') == 'migration':
        raise InstallError('A migration receipt allows update only. Complete the verified update before using removal.')
    if (root / 'envs/science').exists():
        return True
    return owned_science(root)


REMOVAL_STAGES = ('Checking removal targets', 'Checking active processes', 'Removing science environment',
                  'Removing owned launchers', 'Verifying preservation')
REMOVAL_HEARTBEAT_SECONDS = 5


@contextlib.contextmanager
def removal_stage(number):
    label = '[{}/{}] {}'.format(number, len(REMOVAL_STAGES), REMOVAL_STAGES[number - 1])
    start = time.monotonic()
    stopped = threading.Event()

    def heartbeat():
        while not stopped.wait(REMOVAL_HEARTBEAT_SECONDS):
            print('{}  Still working... {:.0f} s elapsed'.format(label, time.monotonic() - start), flush=True)

    print(label + '  RUNNING', flush=True)
    thread = threading.Thread(target=heartbeat, daemon=True)
    thread.start()
    outcome = {'status': 'PASS'}
    try:
        yield outcome
    except (UsageBlocked, OperationBlocked):
        outcome['status'] = 'BLOCKED'
        raise
    except BaseException:
        outcome['status'] = 'FAIL'
        raise
    finally:
        stopped.set()
        thread.join()
        print('{}  {} ({:.0f} s elapsed)'.format(label, outcome['status'], time.monotonic() - start), flush=True)


def remove_science(root, home=None, runner=run_process, busy=using_science, mm=None):
    home = Path(home) if home is not None else Path.home()
    root = Path(root)
    with contextlib.ExitStack() as lock:
        with removal_stage(1):
            safety.plain_path(root, missing=True)
            if not root.exists(): return {'status': 'PASS', 'science_removed': True, 'reason': 'Selected root is already absent.'}
            guard_root(root, home, existing=True)
            prefix = root / 'envs/science'
            lock.enter_context(locked(root))
            guard_root(root, home, existing=True)
            removal_ownership(root)
            if busy(prefix): raise_busy(prefix, 'removed')
            mm = Path(mm) if mm else Path(read_state(root).get('micromamba_exe', str(root / 'bin/micromamba')))
            preserved = lifecycle.preservation(root, home, mm)
            tree = safety.tree_plan(prefix) if prefix.exists() else None
            registry = safety.registry_plan(home, prefix)
            launchers = launcher_removal_plan(root, home)
            receipt = root / '.science-env-owner.json'
            receipt_plan = safety.file_plan(receipt) if receipt.exists() else None
            # Validate every target before the first deletion. No Micromamba command,
            # uninstall hook, package-cache cleanup or Bash edit is executed here.
            safety.check_registry(registry)
            for plan in launchers + ([receipt_plan] if receipt_plan else []): safety.check_file(plan)
            guard_root(root, home, existing=True)
        with removal_stage(2):
            if busy(prefix): raise_busy(prefix, 'removed')
        expected_registry = registry['new'] if registry else b''
        registry_path = Path(registry['path']) if registry else home / '.conda/environments.txt'
        try:
            with removal_stage(3):
                if tree: safety.remove_tree(tree)
                safety.write_registry(registry)
            with removal_stage(4):
                for plan in launchers: safety.unlink_file(plan)
                if receipt_plan: safety.unlink_file(receipt_plan)
        except (OSError, InstallError, KeyboardInterrupt) as error:
            try:
                failed = lifecycle.verify(root, home, mm, preserved, [item['path'] for item in launchers], expected_registry, registry_path, runner, isolated_env(root, mm))
            except (OSError, ValueError, subprocess.SubprocessError) as verification_error:
                failed = {'remaining_targets': [str(prefix)] if prefix.exists() else [], 'verification_error': str(verification_error)}
            failed.update(status='FAIL', changes_may_have_started=True, error_type=type(error).__name__, error=str(error), instruction='Removal may be partial. Do not use the remaining science prefix. Review remaining_targets; retry only if ownership checks permit. Never remove the root/cache or change other environments to work around this error.')
            write_json(root / 'science-removal.json', failed)
            error.removal_report = failed
            raise
        with removal_stage(5) as outcome:
            report = lifecycle.verify(root, home, mm, preserved, [item['path'] for item in launchers], expected_registry, registry_path, runner, isolated_env(root, mm))
            write_json(root / 'science-removal.json', report)
            outcome['status'] = report['status']
    if report['status'] == 'PASS':
        print('Science removal PASS. Owned launchers and registration are gone; Micromamba, shared cache and other environments were verified.')
    else:
        print('Science removal INCOMPLETE. Review ' + str(root / 'science-removal.json') + '. No complete SUCCESS is claimed.')
    return report

def prepare_settings(root, home=None):
    home = Path(home) if home is not None else Path.home()
    root = Path(root)
    target = safety.settings_directory(root, home)
    safety.plain_path(target, missing=True)
    if target.exists():
        owner = safety.json_regular(target / '.science-settings-owner.json')
        if owner != safety.settings_owner(root):
            raise InstallError('A foreign Spyder settings directory will not be modified.')
    else:
        target.mkdir(parents=True)
        write_json(target / '.science-settings-owner.json', safety.settings_owner(root))
    return target


def remove_settings(home=None, root=None):
    home = Path(home) if home is not None else Path.home()
    if root is None:
        raise InstallError('Choose the installation root before removing its Spyder settings.')
    plan = safety.settings_plan(Path(root), home)
    if plan: safety.remove_tree(plan)
    print("Removed only this installation's owned Spyder settings. Shared/legacy Spyder profiles were preserved.")

def root_removal_plan(root, home=None, runner=run_process):
    home = Path(home) if home is not None else Path.home()
    root = guard_root(root, home, existing=True)
    state = read_state(root)
    if state.get('managed_by') != 'scientific-python-ubuntu':
        raise InstallError('Micromamba is not installer-managed; it is preserved.')
    if state.get('mode') == 'existing' or state.get('root_owned') == 'false':
        raise InstallError('Existing Micromamba installations can never be removed.')
    if root != home / 'micromamba':
        raise InstallError('Whole-installation removal is limited to the managed Recommended layout.')
    origin_path = root / '.science-root-owner.json'
    origin = safety.json_regular(origin_path)
    origin_plan = safety.file_plan(origin_path)
    mm = root / 'bin/micromamba'
    if origin.get('managed_by') != 'scientific-python-ubuntu' or origin.get('scope') != 'micromamba-binary' or origin.get('root') != str(root) or origin.get('executable') != str(mm):
        raise InstallError('Micromamba ownership/original installation cannot be confirmed.')
    binary = safety.file_plan(mm)
    if binary['sha256'] != origin.get('sha256'):
        raise InstallError('Micromamba was changed outside this installer; it is preserved.')
    if using_science(root): raise InstallError('Processes still use this installation.')
    registry = safety.root_inventory(root, home, mm, runner)
    launchers = launcher_removal_plan(root, home)
    if read_state(root) != state: raise InstallError('Installation ownership changed during inventory; removal refused.')
    safety.check_file(origin_plan)
    for plan in [binary, *launchers]: safety.check_file(plan)
    return binary, registry, launchers


def remove_root(root, home=None, runner=run_process):
    home = Path(home) if home is not None else Path.home()
    root = Path(root)
    safety.plain_path(root, missing=True)
    if not root.exists(): return
    guard_root(root, home, existing=True)
    with locked(root):
        binary, registry, launchers = root_removal_plan(root, home, runner)
        safety.check_registry(registry)
        if using_science(root): raise InstallError('A process began using this Micromamba installation; removal refused.')
        if any((root / 'envs').iterdir()): raise InstallError('An environment appeared during review; removal refused.')
        for plan in [binary, *launchers]: safety.check_file(plan)
        safety.unlink_file(binary)
        for plan in launchers: safety.unlink_file(plan)
    print('Removed only the verified installer-owned Micromamba executable and its owned launchers. Root directory, cache, user files, registries and Bash configuration were preserved.')

DEDICATED_ROOT_RECEIPT = '.science-dedicated-root.json'
DEDICATED_ROOT_ENTRIES = frozenset('''bin envs pkgs tmp share .scientific-python-installer-state
    .science-root-owner.json .science-env-owner.json .science-installer.lock .science-attempt.json
    .science-update-plan.json .science-transactions .science-startup .science-shells .science-launch
    .science-launchers.json science-runtime.json science-diagnostics.json science-packages.json
    science-launch-context.json science-spyder-kernel.json science-spyder-startup.json
    science-fontconfig-repair.json science-other-environments.json'''.split())


def verify_prefix_scope(prefix, entries, science=False):
    """Recognize package-owned paths and derived bytecode, not arbitrary user files."""
    meta = prefix / 'conda-meta'
    history = ownership_file(meta / 'history', package_metadata=True)
    metadata = {'conda-meta/history'}
    packages = set()
    for path in meta.glob('*.json'):
        if path.stat().st_size > 20 * 1024 * 1024 or len(metadata) > 5000:
            raise InstallError('Conda package metadata limit exceeded: ' + str(path))
        row = json.loads(ownership_file(path, package_metadata=True))
        identity = '-'.join(row.get(key, '') for key in ('name', 'version', 'build'))
        files = row.get('files')
        if path.name != identity + '.json' or not isinstance(files, list):
            raise InstallError('Invalid Conda package inventory: ' + str(path))
        metadata.add('conda-meta/' + path.name)
        for name in files:
            if not isinstance(name, str) or not name or '\\' in name or Path(name).is_absolute() or '..' in Path(name).parts:
                raise InstallError('Unsafe package path in ' + str(path))
            packages.add(str(Path(name)))
    if not metadata - {'conda-meta/history'} and history.strip():
        raise InstallError('Conda history has no package inventory: ' + str(prefix))
    allowed = packages | metadata | {'conda-meta/pinned'}
    if science:
        allowed.add('.science-owner.json')
        support = prefix.parent.parent / 'share/scientific-python'
        for active, group in ((True, 'activate.d'), (False, 'deactivate.d')):
            for filename, content in (
                ('scientific-python-spyder.sh', spyder_profile_hook(prefix.parent.parent, support, active)),
                ('scientific-python-usage.sh', processes.hook_text(prefix, support, active)),
            ):
                path = 'etc/conda/' + group + '/' + filename
                if path in entries:
                    if ownership_file(prefix / path) != content.encode():
                        raise InstallError('Installer activation hook was changed: ' + str(prefix / path))
                    allowed.add(path)
    directories = {str(parent) for path in allowed for parent in Path(path).parents}
    for key, data in entries.items():
        if key in allowed or stat.S_ISDIR(data[2]) and (key in directories or Path(key).name == '__pycache__'):
            continue
        path = Path(key)
        if (stat.S_ISREG(data[2]) and path.parent.name == '__pycache__'
                and re.fullmatch(r'.+\.cpython-\d+(?:\.opt-\d+)?\.pyc', path.name)
                and str(path.parent.parent / (path.name.split('.cpython-', 1)[0] + '.py')) in packages):
            continue
        raise InstallError('Unidentified environment entry: ' + str(prefix / key))


def owned_cache_paths(cache, entries):
    """Verify both flat and channel-scoped Micromamba cache layouts."""
    stores = {cache}
    for key in entries:
        path = Path(key)
        if len(path.parts) > 4 and path.parts[1] in ('file', 'https', 'http') and path.parts[-2:] == ('info', 'index.json'):
            stores.add(cache.parent / path.parent.parent.parent)
    allowed = set()
    for store in stores:
        for ancestor in (store, *store.parents):
            if ancestor.is_relative_to(cache):
                allowed.add(ancestor)
        for path in store.iterdir():
            if path in allowed:
                continue
            if path.name in ('urls.txt', 'urls', '.mamba_lock') and path.is_file() and not path.is_symlink():
                allowed.add(path)
            elif path.name == 'cache' and path.is_dir() and not path.is_symlink():
                allowed.add(path)
                allowed.update(item for item in path.iterdir() if item.is_file() and not item.is_symlink()
                               and re.fullmatch(r'[0-9a-fA-F]{8,64}(?:\.state)?\.(?:json|solv|lock)', item.name))
            elif path.is_file() and not path.is_symlink() and re.fullmatch(r'[^/]+-[^/]+-[^/]+\.(?:conda|tar\.bz2)', path.name):
                allowed.add(path)
            elif path.is_dir() and not path.is_symlink() and (path / 'info/index.json').is_file():
                info = path / 'info'
                row = json.loads(ownership_file(info / 'index.json', package_metadata=True))
                if path.name != '-'.join(row.get(k, '') for k in ('name', 'version', 'build')):
                    continue
                allowed.update({path, info})
                if (info / 'paths.json').is_file():
                    names = [row['_path'] for row in json.loads(ownership_file(info / 'paths.json', package_metadata=True))['paths']]
                else:
                    names = ownership_file(info / 'files', package_metadata=True).decode().splitlines()
                for name in names:
                    if not name or '\\' in name or Path(name).is_absolute() or '..' in Path(name).parts:
                        raise InstallError('Unsafe cache package path in ' + str(path))
                    item = path / name
                    allowed.update(parent for parent in (item, *item.parents) if parent.is_relative_to(path))
                allowed.update(info / name for name in (
                    'index.json','paths.json','repodata_record.json','files','about.json','hash_input.json',
                    'link.json','git','run_exports.json','has_prefix','no_link','no_softlink','test','recipe','licenses'))
                for sub in ('test','recipe','licenses'):
                    if (info / sub).is_dir() and not (info / sub).is_symlink():
                        allowed.update((info / sub).rglob('*'))
    for key in entries:
        path = cache.parent / key
        if path.is_relative_to(cache) and path not in allowed:
            raise InstallError('Unidentified entry in the package cache: ' + str(path))


def dedicated_tree(root, managed=True):
    allowed = DEDICATED_ROOT_ENTRIES if managed else {'bin', 'envs', 'pkgs', '.science-installer.lock'}
    unexpected = {path.name for path in root.iterdir()} - allowed - {DEDICATED_ROOT_RECEIPT, 'conda-meta'}
    if (root / 'conda-meta/history').is_file():
        for record in (root / 'conda-meta').glob('*.json'):
            for file in json.loads(ownership_file(record, package_metadata=True)).get('files', []):
                if isinstance(file, str) and Path(file).parts:
                    unexpected.discard(Path(file).parts[0])
    if unexpected:
        raise InstallError('Unexpected content in root: ' + ', '.join(sorted(unexpected)))
    envs = root / 'envs'
    prefixes = tuple(sorted(envs.iterdir())) if envs.is_dir() else ()
    if len(prefixes) > 128 or any(not (prefix / 'conda-meta/history').is_file() for prefix in prefixes):
        raise InstallError('Unidentified entry inside envs or inventory limit reached.')
    if managed and root / 'envs/science' in prefixes:
        removal_ownership(root)
    if not (root / 'conda-meta').exists() and {path.name for path in (root / 'bin').iterdir()} - {'micromamba', 'science-spyder'}:
        raise InstallError('Unidentified executables exist in the selected root.')
    tree = safety.tree_plan(root, dedicated=True, prefixes=prefixes)
    entries = {key: identity for key, identity in tree['entries'].items() if key != DEDICATED_ROOT_RECEIPT}
    if managed and (root / 'share').is_dir():
        support = root / 'share/scientific-python'
        if not support.is_dir() or set((root / 'share').iterdir()) != {support}:
            raise InstallError('Unexpected installer support directory.')
        science_integrity.verify(support)
        manifest = ownership_file(support / 'SHA256SUMS.txt').decode().splitlines()
        support_files = {line.split('  ', 1)[1] for line in manifest} | {'SHA256SUMS.txt', 'science-release.json'}
        for path in support.rglob('*'):
            name = path.relative_to(support).as_posix()
            if (name in support_files or (path.is_dir() and any(p.startswith(name + '/') for p in support_files))):
                continue
            if re.fullmatch(r'science-release.previous-[0-9a-f]{64}\.json', name) and hashlib.sha256(ownership_file(path)).hexdigest() == name[25:-5]:
                continue
            raise InstallError('Unidentified support entry: ' + str(path))
    if managed and (root / '.science-transactions').is_dir():
        transaction_dir = root / '.science-transactions'
        receipt = ownership_json(transaction_dir / '.owner.json')
        if receipt != {'managed_by': safety.PRODUCT, 'root': str(root), 'scope': 'locked-transactions'}:
            raise InstallError('Transaction evidence is not owned by this root.')
        for directory in transaction_dir.iterdir():
            if directory.name == '.owner.json':
                continue
            if not directory.is_dir() or not re.fullmatch(r'[a-f0-9]{64}', directory.name):
                raise InstallError('Unidentified transaction directory: ' + str(directory))
            lock = ownership_json(directory / 'approved-lock.json')
            if lock.get('prefix') != str(root / 'envs/science') or tx.digest(lock) != directory.name:
                raise InstallError('Transaction evidence disagrees with its locked identity: ' + str(directory))
            known = {'approved-lock.json', 'explicit-local.txt', 'locked-environment.yml', 'locked-preflight.json',
                     'committed-plan.json', 'metadata-restoration.json', 'channel', 'cache', 'private-home'}
            for path in directory.iterdir():
                if path.name not in known and not (path.is_dir() and re.fullmatch(r'download-prefix-[A-Za-z0-9_-]+', path.name)):
                    raise InstallError('Unidentified transaction evidence: ' + str(path))
            cache = directory / 'cache'
            if cache.is_dir():
                base = str(directory.relative_to(root)) + '/'
                owned_cache_paths(cache, {key[len(base):]: value for key, value in entries.items() if key.startswith(base)})
    for prefix in prefixes:
        base = prefix.relative_to(root).as_posix() + '/'
        verify_prefix_scope(prefix, {key[len(base):]: data for key, data in entries.items() if key.startswith(base)},
                            science=managed and prefix.name == 'science')
    if (root / 'conda-meta').exists():
        reserved = (set(allowed) - {'bin'}) | {DEDICATED_ROOT_RECEIPT}
        private = {'bin/micromamba', 'bin/science-spyder'}
        if not any(key.startswith('bin/') and key not in private for key in entries):
            private.add('bin')
        verify_prefix_scope(root, {key: data for key, data in entries.items()
                            if key.split('/')[0] not in reserved and key not in private})
    cache = root / 'pkgs'
    if cache.is_dir():
        owned_cache_paths(cache, entries)
    return tree, fingerprint(entries)


def seal_dedicated_root(root):
    origin = ownership_json(root / '.science-root-owner.json')
    if origin.get('created_root_identity') != [root.stat().st_dev, root.stat().st_ino]:
        raise InstallError('An existing root cannot gain a dedicated-root receipt by updating.')
    tree, digest = dedicated_tree(root)
    target = root / DEDICATED_ROOT_RECEIPT
    if os.path.lexists(target):
        raise InstallError('Dedicated root receipt already exists; it was not replaced.')
    write_json(target, {'managed_by': safety.PRODUCT, 'scope': 'dedicated-root', 'root': str(root),
                        'identity': list(tree['identity']), 'tree_fingerprint': digest})


def total_removal_plan(root, home, inventory):
    root = guard_root(root, home, existing=True)
    origin_path = root / '.science-root-owner.json'
    origin = ownership_json(origin_path) if os.path.lexists(origin_path) else None
    binary = root / 'bin/micromamba'
    digest = hashlib.sha256(ownership_file(binary)).hexdigest()
    if digest not in {release()['MicromambaExeSha256'], *LEGACY_V3_BINARY_HASHES}:
        raise InstallError('The selected root has no verified, independently fingerprinted executable.')
    if origin is not None and (origin.get('scope') != 'micromamba-binary' or origin.get('managed_by') != safety.PRODUCT
            or origin.get('root') != str(root) or origin.get('executable') != str(binary)
            or digest != origin.get('sha256')):
        raise InstallError('The executable disagrees with its installer ownership receipt.')
    managed = bool(origin and read_state(root).get('root_owned') == 'true')
    if origin and not managed:
        raise InstallError('Binary ownership does not establish scope for an existing root with installer artifacts.')
    if managed and origin.get('created_root_identity') is not None:
        info = root.stat()
        if origin['created_root_identity'] != [info.st_dev, info.st_ino]:
            raise InstallError('Selected root identity disagrees with its creation receipt.')
    configs = safety.config_sources(root, home)
    def channels_only(path):
        path = Path(path)
        if path.is_relative_to(root) or not path.is_file() or path.stat().st_size > 32768:
            return False
        lines = [line for line in ownership_file(path).decode().splitlines() if not re.fullmatch(r'\s*(#.*)?', line)]
        return bool(lines and lines[0] == 'channels:' and all(re.fullmatch(r'\s+-\s+[A-Za-z0-9_.-]+\s*', line) for line in lines[1:]))
    if (inventory.get('unknown') or inventory.get('external_cache_settings') or any(not channels_only(path) for path in configs)
            or any(os.environ.get(key) for key in ('CONDA_ENVS_PATH', 'CONDA_ENVS_DIRS', 'MAMBA_ENVS_DIRS'))):
        raise InstallError('Unknown inventory, external cache or custom Conda/Mamba settings prevent proving an exclusive root.')
    for name, row in inventory['details'].items():
        other = Path(name)
        if other != root and (other.is_relative_to(root) or root.is_relative_to(other)):
            raise InstallError('Another detected root overlaps the selected root: ' + name)
        if other != root and other.exists() and ((other / 'pkgs').is_symlink() or any(
            not channels_only(path) for path in safety.config_sources(other, home)
        )):
            raise InstallError('Another detected root has unknown contents or settings; cache isolation cannot be established: ' + name)
    if not Path('/proc/self').is_dir():
        raise InstallError('Process inventory is unavailable.')
    if using_science(root) or using_science(root / 'envs/science') or (
        os.environ.get('CONDA_PREFIX') and Path(os.environ['CONDA_PREFIX']).is_relative_to(root)
    ):
        raise InstallError('A process or the calling shell uses the selected root. Start a clean terminal after closing all users.')
    tree, _ = dedicated_tree(root, managed)
    for prefix in tree['prefixes']:
        if using_science(prefix):
            raise InstallError('An active process uses ' + str(prefix))
    if not managed and not (tree['prefixes'] or (root / 'conda-meta/history').is_file()):
        raise InstallError('User-managed root needs independently identifiable Conda environments.')
    if os.path.lexists(root / DEDICATED_ROOT_RECEIPT):
        receipt = ownership_json(root / DEDICATED_ROOT_RECEIPT)
        if not managed or any(receipt.get(k) != v for k, v in {'managed_by': safety.PRODUCT, 'scope': 'dedicated-root',
               'root': str(root), 'identity': list(tree['identity'])}.items()):
            raise InstallError('The recorded dedicated root identity does not match.')
    for name in ('.bashrc', '.bash_profile', '.bash_login', '.profile', '.local/share/scientific-python/micromamba-shell.sh'):
        path = home / name
        if os.path.lexists(path) and os.fsencode(root) in ownership_file(path):
            raise InstallError('Shell configuration directly references the root; review this file before removal: ' + str(path))
    registry = safety.registry_plan(home)
    if registry:
        included = {root, *tree['prefixes']}
        if any(path.is_relative_to(root) and path not in included for path in registry['paths']):
            raise InstallError('An unexpected registered environment is inside the selected root.')
        if any(path != root and root.is_relative_to(path) for path in registry['paths']):
            raise InstallError('An external registered environment contains the selected root.')
        registry['new'] = b''.join(line for line in registry['original'].splitlines(keepends=True)
                                   if os.fsdecode(line.rstrip(b'\r\n')) not in {str(item) for item in included})
    return {'tree': tree, 'registry': registry,
            'launchers': [plan for plan in launcher_removal_plan(root, home) if not Path(plan['path']).is_relative_to(root)]}


def apply_total_removal(root, home, approved, inventory):
    lock_name = '.science-installer.lock'
    # A standalone Micromamba root has no installer lock until Apply.
    # Compare before creating it and exclude only that one creation afterward.
    if total_removal_plan(root, home, inventory()) != approved:
        raise InstallError('Deletion plan changed after approval; no targets removed.')
    lock_expected = lock_name in approved['tree']['entries']
    with locked(root):
        current = total_removal_plan(root, home, inventory())
        comparison = current
        if not lock_expected:
            comparison = {**current, 'tree': {**current['tree'], 'entries': {
                name: data for name, data in current['tree']['entries'].items() if name != lock_name}}}
        if comparison != approved:
            raise InstallError('Deletion plan changed after approval; no targets removed.')
        completed = []
        remaining = [str(root), *[item['path'] for item in current['launchers']]]
        if current['registry'] and current['registry']['new'] != current['registry']['original']:
            remaining.append('selected entries in ' + current['registry']['path'])
        try:
            safety.check_registry(current['registry'])
            for plan in current['launchers']:
                safety.check_file(plan)
            safety.remove_tree(current['tree'])
            completed.append(remaining.pop(0))
            for plan in current['launchers']:
                safety.unlink_file(plan)
                completed.append(remaining.pop(0))
            if remaining:
                safety.write_registry(current['registry'])
                completed.append(remaining.pop(0))
        except (OSError, safety.SafetyError, KeyboardInterrupt) as exc:
            raise InstallError(json.dumps({'status': 'PARTIAL_OR_BLOCKED', 'root': str(root), 'completed': completed,
                'remaining_or_incomplete': remaining, 'preserved': 'Other roots, external environments/caches, settings and user package configuration',
                'reason': str(exc), 'recovery': 'Inspect the remaining paths and backup before retrying; no rollback was attempted.'}, indent=2)) from exc
        return completed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['config', 'spyder-profile', 'guard-platform', 'bootstrap', 'sync', 'profile', 'artifacts', 'guard-root', 'guard-remove', 'diagnostics', 'verify-bundle', 'state', 'remove-science', 'remove-root', 'remove-settings', 'clean-launchers'])
    parser.add_argument('--root', type=Path, default=Path.home() / 'micromamba')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--remove', action='store_true')
    parser.add_argument('--allow-new', action='store_true')
    args = parser.parse_args()
    if args.action == 'spyder-profile':
        print(prepare_spyder_profile(args.root)); return 0
    config = release()
    if args.action == 'config':
        print('\t'.join(config[k] for k in ['InstallerVersion', 'MicromambaVersion', 'Python', 'Spyder']))
        return 0
    if args.action == 'verify-bundle':
        verify_bundle(); return 0
    if args.action == 'diagnostics':
        diagnostics(args.root, args.output or args.root / 'science-diagnostics.json'); return 0
    platform_guard()
    if args.action == 'guard-platform':
        return 0
    if args.action in ['bootstrap', 'sync']:
        science_config.initialize(BUNDLE, root=args.root)
        config = release()
        science_config.require_workflow(config)
    if args.action == 'bootstrap':
        bootstrap(args.root, config)
    elif args.action == 'sync':
        sync(args.root, config)
    elif args.action == 'profile':
        profile(args.root, remove=args.remove)
    elif args.action == 'artifacts':
        artifacts(args.root)
    elif args.action == 'state':
        mark_complete(args.root, config)
    elif args.action == 'remove-science':
        report = remove_science(args.root)
        return 0 if report and report.get('status') == 'PASS' else 1
    elif args.action == 'remove-root':
        remove_root(args.root)
    elif args.action == 'remove-settings':
        remove_settings(root=args.root)
    elif args.action == 'clean-launchers':
        clean_launchers(args.root)
    else:
        guard_root(args.root, allow_new=args.allow_new)
        if args.action == 'guard-remove':
            root_removal_plan(args.root)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (InstallError, OSError, ValueError, configparser.Error, subprocess.SubprocessError, tarfile.TarError) as exc:
        print('ERROR: ' + str(exc), file=sys.stderr)
        sys.exit(1)
