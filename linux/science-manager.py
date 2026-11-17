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


def owned_science(root):
    root = Path(root)
    prefix = root / 'envs/science'
    receipt_path = root / '.science-env-owner.json'
    owner_path = prefix / '.science-owner.json'
    receipt = None
    for path in [receipt_path, owner_path]:
        if os.path.lexists(path):
            value = safety.json_regular(path)
            if value.get('managed_by') != 'scientific-python-ubuntu' or value.get('root') != str(root):
                raise InstallError('Conflicting environment ownership metadata.')
            if path == receipt_path: receipt = value
    if owner_path.is_file(): return True
    if receipt and receipt.get('prefix') == str(prefix):
        if not prefix.exists(): return True  # Own reports/reservation, no environment to alter.
        # Only an empty downloader-created skeleton is authorized by a reservation.
        # A device/inode tuple or package fingerprint is not durable ownership:
        # directory identities can be reused, and unrelated envs can have identical packages.
        if receipt.get('phase') == 'download' and receipt.get('prefix_identity') is None:
            paths = {str(item.relative_to(prefix)) for item in prefix.rglob('*')}
            allowed = {'conda-meta', 'conda-meta/history'}
            history = prefix / 'conda-meta/history'
            return paths <= allowed and not history.is_symlink() and (not history.exists() or safety.read_regular(history)[0] == b'')
    return False


def guard_science(root):
    prefix = Path(root) / 'envs/science'
    if prefix.exists() and not owned_science(root):
        raise InstallError('science exists without installer ownership; nothing was overwritten.')


def approve_plan(plan, before, after):
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
                     (MARKER + '\ninstaller_version=' + config['InstallerVersion'] + '\nstatus=prepared\nlayout=home\n').encode(), 0o600)
    if created_root:
        write_json(root / '.science-root-owner.json', {'managed_by': 'scientific-python-ubuntu', 'scope': 'micromamba-binary',
            'root': str(root), 'executable': str(root / 'bin/micromamba'), 'sha256': config['MicromambaExeSha256']})
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
        if created_root:
            write_json(root / '.science-root-owner.json', {'managed_by': 'scientific-python-ubuntu', 'scope': 'micromamba-binary',
                'root': str(root), 'executable': str(mm), 'sha256': config['MicromambaExeSha256']})
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
        command = 'update' if before else 'create'
        argv = [mm, command, '--no-rc', '-r', root, '-p', prefix, '--override-channels', *[arg for channel in config['Channels'] for arg in ['-c', channel]],
                '--strict-channel-priority', '--no-pyc', '--json']
        if command == 'update':
            argv += ['--all']
        argv += requested
        write_json(root / '.science-attempt.json', {'status': 'preflight', 'package_changes_started': False})
        result = runner(argv + ['--dry-run'], env=env)
        if result.returncode:
            write_json(root / '.science-attempt.json', {'status': 'preflight_failed', 'exit_code': result.returncode, 'package_changes_started': False})
            print(result.stdout, end=''); print(result.stderr, file=sys.stderr, end='')
            raise InstallError('Dependency solve failed before package changes. Incompatible extra packages or version pins must be resolved; OpenCV/FFmpeg limits are unchanged.')
        if result.stderr: print(result.stderr, file=sys.stderr, end='')
        plan = parse_plan(result.stdout)
        after = check_plan(plan, before, config, history_specs(prefix))
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
    prefix = root / 'envs/science'
    receipt = root / '.science-env-owner.json'
    owner = prefix / '.science-owner.json'
    proofs = []
    for path in [receipt, owner]:
        if os.path.lexists(path):
            value = safety.json_regular(path)
            if value.get('managed_by') != 'scientific-python-ubuntu' or value.get('root') != str(root):
                raise InstallError('Conflicting environment ownership proof; science is preserved.')
            proofs.append(path)
    if prefix.exists() and not owned_science(root):
        raise InstallError('No reliable ownership proof for this science directory; no deletion allowed.')
    if not prefix.exists() and not proofs:
        return False
    return True


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
