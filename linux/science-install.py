#!/usr/bin/env python3
"""Interactive V4-r5.2 workflow with approved user-local maintenance."""
import argparse
import datetime
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import signal
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time

BUNDLE = Path(__file__).resolve().parent
_integrity_spec = importlib.util.spec_from_file_location('science_install_integrity', BUNDLE / 'science_integrity.py')
science_integrity = importlib.util.module_from_spec(_integrity_spec)
_integrity_spec.loader.exec_module(science_integrity)
try:
    science_integrity.verify(BUNDLE)
except (ValueError, OSError) as exc:
    raise SystemExit('ERROR: ' + str(exc)) from None
spec = importlib.util.spec_from_file_location('science_manager', BUNDLE / 'science-manager.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
LABELS = ['Checking operating system', 'Selecting Micromamba root', 'Checking Micromamba',
          'Resolving dependencies', 'Reviewing package changes', 'Installing packages',
          'Installing Spyder launchers', 'Running automatic tests', 'Finalizing installation']


def step(number, status):
    print('[{}/9] {:32} {}'.format(number, LABELS[number - 1], status), flush=True)


def ask(prompt, default=None, reader=input):
    answer = reader(prompt).strip()
    return answer if answer else default


def index_file(home):
    return Path(home) / '.local/state/scientific-python/installations.json'


def read_index(home):
    path = index_file(home)
    m.safety.plain_path(path, missing=True)
    if not path.exists(): return []
    if not path.is_file() or path.stat().st_size > 256 * 1024: raise m.InstallError('Installation index is not a bounded regular file.')
    value = json.loads(path.read_text())
    if not isinstance(value, list) or not all(isinstance(item, str) and Path(item).is_absolute() for item in value): raise m.InstallError('Invalid installation index.')
    return value


def expand_path(value, home):
    if value == '~': value = str(home)
    elif value.startswith('~/'): value = str(home / value[2:])
    path = Path(value)
    if not path.is_absolute(): raise m.InstallError('Please enter an absolute path or ~/path.')
    return path


def detect(home=None, env=None, runner=m.run_process):
    home = Path(home) if home is not None else Path.home()
    env = os.environ if env is None else env
    roots = {}; executables = []; unverified = []; matched = {}
    policy = m.science_config.read_json(BUNDLE / 'science-installer-release.json')
    allowed_hashes = {policy['MicromambaExeSha256'], *m.LEGACY_V3_BINARY_HASHES}
    def root(value, source):
        if not value: return
        path = Path(value)
        if path.is_absolute() and '..' not in path.parts and len(roots) < 64:
            sources = roots.setdefault(str(path), [])
            if source not in sources:
                sources.append(source)
    def exe(value):
        if not value or len(executables) + len(unverified) >= 32:
            return
        path = Path(value)
        if str(path) in executables or str(path) in unverified:
            return
        try:
            m.safety.plain_path(path)
            info = path.lstat()
            if not path.is_file() or info.st_size > 100 * 1024 * 1024 or info.st_mode & 0o022 or not os.access(path, os.X_OK):
                raise ValueError('Untrusted executable file')
            if hashlib.sha256(m.safety.read_regular(path)[0]).hexdigest() not in allowed_hashes:
                raise ValueError('Unknown executable fingerprint')
        except (OSError, ValueError, m.safety.SafetyError):
            unverified.append(str(path))
            return
        executables.append(str(path))
    root(env.get('MAMBA_ROOT_PREFIX'), 'MAMBA_ROOT_PREFIX')
    if env.get('CONDA_PREFIX'):
        prefix = Path(env['CONDA_PREFIX'])
        if prefix.parent.name == 'envs':
            root(str(prefix.parent.parent), 'active Conda prefix')
    exe(env.get('MAMBA_EXE'))
    exe(shutil.which('micromamba', path=env.get('PATH', '')))
    bashrc = home / '.bashrc'
    try:
        m.safety.plain_path(bashrc)
        text = bashrc.read_text(errors='replace') if bashrc.is_file() and bashrc.stat().st_size <= 256 * 1024 else ''
    except (m.safety.SafetyError, OSError):
        text = ''
    # Inspect literal assignments without sourcing arbitrary user shell code.
    for name, value in re.findall(r'''(?:export\s+)?(MAMBA_ROOT_PREFIX|MAMBA_EXE)\s*=\s*['"]?([^'";\n]+)''', text):
        value = value.strip().replace('${HOME}', str(home)).replace('$HOME', str(home))
        if '$' in value or '`' in value: continue
        if name == 'MAMBA_EXE': exe(value)
        else: root(value, 'Bash activation')
    external = []; unknown = []
    try:
        registry_path = home / '.conda/environments.txt'
        m.safety.plain_path(registry_path, missing=True)
        if registry_path.exists() and registry_path.stat().st_size > 256 * 1024:
            raise ValueError('Environment registry exceeds the inventory bound')
        registered = (m.safety.registry_plan(home) or {'paths': []})['paths']
    except (m.safety.SafetyError, OSError, ValueError) as error:
        registered = []; unknown.append('Environment registry: ' + str(error))
    try:
        indices = read_index(home)
    except (m.safety.SafetyError, m.InstallError, OSError, ValueError) as error:
        indices = []; unknown.append('Installation index: ' + str(error))
    known = {home / 'micromamba', home / '.local/share/mamba', *map(Path, roots), *map(Path, indices[:32])}
    for prefix in registered[:128]:
        parent = prefix.parent.parent
        if prefix.parent.name == 'envs' and (parent in known or (parent / 'bin/micromamba').is_file()):
            root(str(parent), 'environment registry')
        elif prefix not in known:
            external.append(str(prefix))
    if len(registered) > 128:
        unknown.append('Additional registry entries were not enumerated')
    for path in dict.fromkeys([*map(Path, roots), home / 'micromamba', home / '.local/share/mamba', *map(Path, indices[:32])]):
        try:
            m.safety.plain_path(path)
            if not path.is_dir():
                continue
            root(str(path), 'existing directory')
            binary = path / 'bin/micromamba'
            if os.path.lexists(binary):
                exe(binary)
                if str(binary) in executables:
                    matched.setdefault(str(path), []).append(str(binary))
        except (m.safety.SafetyError, OSError):
            continue
    # Probe only a fingerprinted active/known executable; HOME and config are isolated.
    if (home / '.local/bin/micromamba').exists():
        exe(home / '.local/bin/micromamba')
    for binary in executables:
        try:
            with tempfile.TemporaryDirectory(prefix='science-inventory-') as temp:
                probe = dict(PATH=os.defpath, HOME=temp, XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp, XDG_DATA_HOME=temp, LC_ALL='C')
                active = env.get('MAMBA_ROOT_PREFIX')
                # Isolate even the root; report associations from corroborated local evidence.
                result = runner([binary, 'info', '--json', '--no-rc', '-r', temp], env=probe, timeout=15)
                value = json.loads(result.stdout) if result.returncode == 0 else {}
                if value.get('base environment') == temp and binary == env.get('MAMBA_EXE') and active in roots:
                    matched.setdefault(active, [])
                    if binary not in matched[active]:
                        matched[active].append(binary)
                    root(active, 'micromamba info: ' + binary)
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
    details = {}
    for name in roots:
        path = Path(name)
        row = {'executables': matched.get(name, []), 'environments': [], 'unknown': [], 'ownership': 'unverified'}
        try:
            m.safety.plain_path(path)
            if not path.is_dir():
                raise ValueError('Root is not a directory')
            row['environments'] = ['base'] if (path / 'conda-meta/history').is_file() else []
            children = m.safety.plain_path(path / 'envs', missing=True)
            if children.is_dir():
                with os.scandir(children) as scan:
                    for i, item in enumerate(scan):
                        if i == 128:
                            row['unknown'].append('Additional envs entries were not enumerated'); break
                        if item.is_dir(follow_symlinks=False) and not (Path(item.path) / 'conda-meta').is_symlink() and (Path(item.path) / 'conda-meta/history').is_file():
                            row['environments'].append(item.name)
                        else:
                            row['unknown'].append(item.name)
            if 'science' in row['environments'] and m.owned_science(path):
                row['ownership'] = 'verified Science environment'
        except (m.safety.SafetyError, m.InstallError, OSError, ValueError) as error:
            row['unknown'].append(str(error))
        details[name] = row
    return {'roots': roots, 'executables': executables, 'unverified_executables': unverified, 'details': details,
            'registered_external': [value for value in external if value not in roots], 'unknown': unknown,
            'external_cache_settings': [name for name in ('CONDA_PKGS_DIRS', 'MAMBA_PKGS_DIRS', 'CONDARC', 'MAMBARC') if env.get(name)],
            'bash_activation': 'mamba initialize' in text or 'shell hook' in text,
            'prior': [name for name, row in details.items() if 'science' in row['environments']]}


def verified_existing_binary(home, root, detection, config):
    """Verify the active choice using the V4-r5 ownership receipt for its location."""
    active = os.environ.get('MAMBA_EXE', '')
    binary = Path(active)
    if active not in detection['executables']:
        raise m.InstallError('The active MAMBA_EXE is missing or differs from the detected executable paths.')
    if binary == home / '.local/bin/micromamba':
        receipt = home / '.local/share/scientific-python/micromamba-owner.json'
    elif binary == root / 'bin/micromamba':
        receipt = root / '.science-root-owner.json'
    else:
        raise m.InstallError('The active executable has no supported installer ownership receipt.')
    for path in (receipt, binary):
        m.safety.plain_path(path)
        info = path.stat()
        if not path.is_file() or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise m.InstallError('Ownership or write permissions are ambiguous: ' + str(path))
    owner = m.safety.json_regular(receipt)
    expected = {'managed_by': m.safety.PRODUCT, 'root': str(root), 'executable': active,
                'sha256': config['MicromambaExeSha256']}
    if receipt.parent == root:
        expected['scope'] = 'micromamba-binary'
    if any(owner.get(key) != value for key, value in expected.items()):
        raise m.InstallError('Executable ownership receipt differs from the selected root or release.')
    if hashlib.sha256(m.safety.read_regular(binary)[0]).hexdigest() != expected['sha256']:
        raise m.InstallError('Executable SHA-256 differs from the release.')
    if 'micromamba info: ' + active not in detection['roots'].get(str(root), []):
        raise m.InstallError('Micromamba info did not confirm the selected Existing root.')
    if check_micromamba(binary, root, config, require_contract=False) != config['MicromambaVersion']:
        raise m.InstallError('Executable version differs from the release.')
    if shutil.which('micromamba') != active or not normal_micromamba_selection(binary, root, home, verify_hook=True):
        raise m.InstallError('Current PATH, Bash executable or Bash root differs from the selected installation.')
    return binary


def select(home=None, detection=None, reader=input, manage_science=True):
    home = Path(home) if home is not None else Path.home()
    detection = detect(home) if detection is None else detection
    roots = detection['roots']
    usable = {name: row['executables'] for name, row in detection['details'].items() if row['executables'] and Path(name).is_dir()}
    default = '3' if usable else '1'
    print('''\n1 – Recommended: ~/micromamba
    Recommended for a new installation; easy to find and manage.
    Environments and package cache are kept together.
2 – XDG: ~/.local/share/mamba
    Linux per-user application data layout; keeps the home directory tidy.
    Functionality is the same as Recommended.
3 – Existing
    Reuses your executable and root, avoids a parallel root and preserves other environments.
    Micromamba 2.10.0 user-local promotion is offered separately; the root is retained.
4 – Custom
    Choose a dedicated directory, for example on a separate disk.
    Paths and write permissions are checked; unmanaged files are never replaced.''')
    if detection['prior']:
        print('Previous Scientific Python root(s): ' + ', '.join(detection['prior']))
        if set(detection['prior']) & set(usable):
            print('Recommendation: retain the previous root (Existing).')
        else:
            print('Those roots do not have a verified executable association. Inspect Info before retrying.')
    choice = ask('Micromamba layout [{}]: '.format(default), default, reader)
    if choice not in ['1', '2', '3', '4']: raise m.InstallError('Invalid layout selection.')
    mode = {'1': 'Recommended', '2': 'XDG', '3': 'Existing', '4': 'Custom'}[choice]
    if choice == '3':
        if not usable: raise m.InstallError('No verified root/executable pair found. See Info for unverified candidates; do not overwrite an existing environment.')
        candidates = list(usable)
        if len(candidates) > 1:
            print('Conflicting/different roots were detected. Select explicitly:')
            for i, value in enumerate(candidates, 1): print(' {}: {} ({})'.format(i, value, ', '.join(roots[value])))
            answer = ask('Existing root number or absolute path (no default): ', reader=reader)
            if not answer: raise m.InstallError('An explicit root is required when roots differ.')
            if answer.isdigit() and 1 <= int(answer) <= len(candidates): answer = candidates[int(answer) - 1]
        else:
            suggested = candidates[0] if candidates else None
            answer = ask('Existing root [{}]: '.format(suggested or 'absolute path required'), suggested, reader)
        if not answer: raise m.InstallError('No root selected.')
        root = expand_path(answer, home)
        m.guard_root(root, home, existing=True)
        binaries = usable.get(str(root))
        if not binaries:
            raise m.InstallError('The selected root has no verified executable association. No changes made.')
        config = m.release()
        try:
            mm = verified_existing_binary(home, root, detection, config)
            if str(mm) not in binaries:
                raise m.InstallError('The active binary does not match this root.')
        except (m.InstallError, OSError, ValueError, subprocess.SubprocessError) as error:
            print('Automatic selection unavailable: ' + str(error))
            if len(binaries) > 1:
                for i, value in enumerate(binaries, 1): print(' {}: {}'.format(i, value))
                selected = ask('Micromamba executable number (no default): ', reader=reader)
                if not selected or not selected.isdigit() or not 1 <= int(selected) <= len(binaries):
                    raise m.InstallError('Select an existing executable explicitly.')
                mm = Path(binaries[int(selected) - 1])
            else:
                mm = Path(binaries[0])
                print('Using the only detected Existing executable: ' + str(mm))
        else:
            print('Micromamba {} selected automatically.\nExecutable: {}\nRoot: {}\nStatus: VERIFIED'
                  .format(config['MicromambaVersion'], mm, root), flush=True)
    else:
        root = home / ('micromamba' if choice == '1' else '.local/share/mamba') if choice != '4' else expand_path(ask('Custom root (absolute path or ~/path): ', reader=reader) or '', home)
        m.guard_root(root, home, allow_new=True)
        mm = root / 'bin/micromamba'
    if manage_science: m.guard_science(root)
    return mode, root, mm


def select_inventory_root(detection, env=None, reader=input, removal=False, total=False):
    env = os.environ if env is None else env
    if removal and not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise m.InstallError('Removal selection requires an interactive terminal.')
    details = detection['details']
    roots = [name for name in details if Path(name).is_dir()]
    if not roots:
        raise m.InstallError('No existing Micromamba root was identified.')
    science = [name for name in roots if details[name]['ownership'] == 'verified Science environment']
    active = [name for name in science if env.get('CONDA_PREFIX') == str(Path(name) / 'envs/science')]
    default = active[0] if len(active) == 1 else (science[0] if len(science) == 1 and len(detection['prior']) == 1 else None)
    print('Micromamba inventory (bounded; externally registered: {}):'.format(', '.join(detection['registered_external']) or 'none found'))
    for number, name in enumerate(roots, 1):
        row = details[name]
        print('[{}] {}: {}; environments: {}; unknown: {}'.format(number, name, row['ownership'],
              ', '.join(row['environments']) or 'none found', ', '.join(row['unknown']) or 'none found'))
    print('[0] Cancel')
    key = str(roots.index(default) + 1) if default is not None else None
    answer = ask('Select root [{}]: '.format(key or 'no default'), key, reader)
    if answer in (None, '0'):
        return None, None
    if not answer.isascii() or not answer.isdecimal() or len(answer) > 3 or not 1 <= int(answer) <= len(roots):
        raise m.InstallError('Invalid inventory selection.')
    name = roots[int(answer) - 1]
    root = Path(name)
    if str(root.resolve()) != name:
        raise m.InstallError('Root is redirected or noncanonical. No changes made.')
    if removal and not total and name != default and reader('Type the exact selected root {}: '.format(name)) != name:
        raise m.InstallError('The root path did not match exactly. No changes made.')
    binaries = details[name]['executables']
    mm = Path(env['MAMBA_EXE']) if env.get('MAMBA_EXE') in binaries else (Path(binaries[0]) if len(binaries) == 1 else None)
    return (root, mm, name == default) if total else (root, mm)


def confirm_total_removal(root, is_default, reader=input, output=print):
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise m.InstallError('Total Remove requires interactive terminal input and output.')
    phrase = 'Yes, I do understand.'
    try:
        if not is_default and reader('Type the exact selected root {}: '.format(root)) != str(root):
            return False
        output('FIRST CONFIRMATION: {} and all listed contents will be permanently removed.'.format(root))
        if reader('Type exactly "{}": '.format(phrase)) != phrase:
            return False
        output('FINAL CONFIRMATION: removal of {} cannot be undone.'.format(root))
        return reader('Type again exactly "{}": '.format(phrase)) == phrase
    except (EOFError, KeyboardInterrupt):
        return False


def total_remove_action(root, home, detected, is_default):
    plan = m.total_removal_plan(root, home, detected)
    print('DELETE the whole directory: ' + str(root))
    print('DELETE executable: ' + str(root / 'bin/micromamba'))
    print('DELETE private cache: ' + str(root / 'pkgs'))
    if (root / 'conda-meta/history').is_file():
        print('DELETE environment: base')
    for prefix in plan['tree']['prefixes']:
        print('DELETE environment: ' + str(prefix))
    for launcher in plan['launchers']:
        print('DELETE owned launcher: ' + launcher['path'])
    if plan['registry'] and plan['registry']['original'] != plan['registry']['new']:
        print('REMOVE only registrations for the listed prefixes from: ' + plan['registry']['path'])
    print('PRESERVE: other roots, external environments and caches, shared Bash settings, Spyder settings and package configuration.')
    if not confirm_total_removal(root, is_default):
        print('Cancelled. Nothing was removed.')
        return 0
    print('Removed targets: ' + json.dumps(m.apply_total_removal(root, home, plan, lambda: detect(home))))
    return 0


def review_migration(root, home, reader=input):
    prefix = root / 'envs/science'
    if not prefix.exists() or m.owned_science(root):
        return None
    try:
        evidence = m.migration_evidence(root, home)
    except (m.InstallError, m.safety.SafetyError, OSError, ValueError) as error:
        raise m.InstallError('Cannot verify legacy Science: {}. The environment was preserved. Compare the original installer state, launcher, configuration and Conda history with a trusted backup. If these cannot be recovered, choose a separate new root and leave {} intact.'.format(error, prefix)) from error
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise m.InstallError('Legacy migration requires an interactive terminal. No changes made.')
    print('Verified legacy Science evidence: {} at {}. This migration allows an update; it does not authorize root, cache or environment removal.'.format(evidence['format'], prefix))
    if ask('Approve environment ownership metadata migration? [y/N]: ', 'n', reader).lower() not in ('y', 'yes'):
        raise PreparationPending('Legacy migration declined. The existing environment was preserved.')
    return evidence


def check_micromamba(mm, root, config, runner=m.run_process, require_contract=True):
    result = runner([mm, '--version'], env=m.isolated_env(root, mm), timeout=15)
    if result.returncode: raise m.InstallError('Micromamba version check failed: ' + result.stderr)
    actual = result.stdout.strip()
    m.version(actual)
    if not require_contract: return actual
    if m.version(actual) < m.version('2.3.2'):
        raise m.InstallError('Existing Micromamba must be >=2.3.2 and support the tested CLI contract.')
    for args, required in [(['create', '--help'], ['--dry-run', '--download-only', '--no-pyc', '--offline', '--json']),
                           (['update', '--help'], ['--all', '--dry-run']), (['env', 'update', '--help'], ['--prune', '--file', '--dry-run']), (['run', '--help'], ['--prefix']),
                           (['env', 'remove', '--help'], ['--prefix'])]:
        probe = runner([mm, *args], env=m.isolated_env(root, mm), timeout=15)
        if probe.returncode or not all(flag in probe.stdout for flag in required):
            raise m.InstallError('Existing Micromamba lacks required functions: ' + ' '.join(args))
    return actual


class PreparationPending(m.InstallError):
    pass


def normal_micromamba_selection(mm, root, home, verify_hook=False):
    inherited = os.environ.get('MAMBA_EXE')
    if not inherited or Path(inherited).resolve() != Path(mm).resolve() or os.environ.get('MAMBA_ROOT_PREFIX') != str(root):
        return False
    script = ('test "$MAMBA_EXE" = ' + shlex.quote(str(mm)) +
              ' && test "$MAMBA_ROOT_PREFIX" = ' + shlex.quote(str(root)) +
              ' && test "$(micromamba --version)" = 2.10.0')
    if verify_hook:
        # The native Bash hook embeds the path of the executable that produced it.
        # This also detects a function dispatching to a different same-version binary.
        script += """ || exit 1
            test "$(type -t micromamba)" = function && test "$(type -P micromamba)" = "$MAMBA_EXE" || exit 1
            args=(shell hook --no-rc --shell bash --root-prefix "$MAMBA_ROOT_PREFIX")
            expected=$("$MAMBA_EXE" "${args[@]}") && actual=$(micromamba "${args[@]}") &&
                [[ -n $expected && $actual == "$expected" ]]
        """
    env = os.environ.copy(); env['HOME'] = str(home)
    try:
        result = m.run_process(['bash', '--noprofile', '--rcfile', home / '.bashrc', '-ic', script], env=env, timeout=30)
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def ensure_micromamba(mm, root, config, home, reader=input):
    actual = check_micromamba(mm, root, config, require_contract=False)
    if actual == config['MicromambaVersion']:
        check_micromamba(mm, root, config)
    if actual == config['MicromambaVersion'] and normal_micromamba_selection(mm, root, home):
        return mm, actual
    current_root = os.environ.get('MAMBA_ROOT_PREFIX')
    if current_root and Path(current_root).resolve() != Path(root).resolve():
        raise PreparationPending('The normal Bash root differs from the selected installation root. No automatic root migration or binary/shell switch was performed. Select the current root with Existing, or explicitly configure the intended root in your calling Bash and restart. Current root: ' + current_root + '; selected root: ' + str(root))
    if actual == config['MicromambaVersion']:
        print('The binary is already at the target version. Bash/PATH selection still needs verification or setup; the verified binary will be reused.')
    print('Current Micromamba: ' + actual + ' at ' + str(mm))
    print('Target: ' + config['MicromambaVersion'] + ' at ' + str(home / '.local/bin/micromamba'))
    print('The system executable is retained. Only approved per-user binary/Bash selection files are changed and backed up. No environment packages are changed.')
    if ask('Approve this separate user-local Micromamba version change? [y/N]: ', 'n', reader).lower() != 'y':
        raise PreparationPending('Micromamba version change declined. Current selection is preserved; no science package changes were started.')
    tools = m.helper('micromamba')
    try:
        result = tools.promote(home, root, mm, config, m)
    except RuntimeError as error:
        raise m.InstallError('Micromamba preparation was blocked; existing setup is retained. ' + str(error)) from error
    print(json.dumps(result, indent=2))
    if result['status'] != 'PASS':
        raise m.InstallError('Micromamba promotion failed and settings were restored. ' + result.get('reason', '') + ' Backup: ' + result['backup'])
    # A child process cannot replace its calling shell's existing function/env.
    # Stop before installing packages; the next fresh terminal uses the same
    # selected executable for both the installer and normal micromamba commands.
    raise PreparationPending(result['instruction'] + '\nPromotion completed; science installation is PENDING, not FAIL. Backup: ' + result['backup'])


def recheck_usage(prefix, operation, reader=input):
    while True:
        report = m.processes.inspect(prefix)
        if report['status'] == 'PASS': return True
        print('[usage] BLOCKED\n' + m.processes.guidance(report, operation), flush=True)
        if any(item['kind'] == 'current_shell' for item in report['blockers']):
            print('Exit this installer, run micromamba deactivate in its calling terminal, then relaunch. Recheck can only refresh other processes, not the inherited parent-shell environment.')
        if ask('Recheck [r] or return without changes [q]? ', 'q', reader).lower() != 'r': return False


def remove_action(root, mm, home, reader=input):
    logdir = home / '.local/state/scientific-python/logs';m.safety.plain_path(logdir, missing=True);logdir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    log = logdir / (stamp + '.removal.log');report_path = logdir / (stamp + '.removal.json')
    old_out, old_err = sys.stdout, sys.stderr;result = {'status': 'BLOCKED', 'phase': 'preconditions'}
    with log.open('x') as stream:
        os.chmod(log, 0o600);sys.stdout, sys.stderr = Tee(old_out, stream), Tee(old_err, stream)
        try:
            print('Scientific Python Ubuntu V4-r5.2 — science removal')
            print('Selected environment: ' + str(root / 'envs/science'))
            if not recheck_usage(root / 'envs/science', 'removed', reader):
                result.update(usage=m.processes.inspect(root / 'envs/science'),instruction='Resolve the listed science users and run removal again. No deletion was started.');return 2
            if ask('Remove only the owned science environment and launchers? [y/N]: ', 'n', reader).lower() != 'y':
                result.update(status='PENDING',reason='Removal was not approved.');return 2
            while True:
                try:
                    result = m.remove_science(root, home=home, mm=mm, runner=logged_runner)
                    result = result or {'status': 'FAIL', 'reason': 'No post-removal verification report was returned.'}
                    print(json.dumps(result, indent=2));return 0 if result['status'] == 'PASS' else 1
                except m.OperationBlocked as error:
                    result = {'status':'BLOCKED','phase':'installer_lock','reason':str(error)}
                    print(str(error))
                    if ask('Recheck installer lock [r] or return [q]? ', 'q', reader).lower() != 'r': return 2
                except m.UsageBlocked as error:
                    result = {'status':'BLOCKED','usage':error.report,'reason':str(error)}
                    print(str(error))
                    if not recheck_usage(root / 'envs/science', 'removed', reader):return 2
        except (m.InstallError, OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            result=getattr(error, 'removal_report', {'status':'FAIL','reason':str(error),'instruction':'Review the named target and ownership/registry checks. Do not remove the root or shared cache. Retry only the science operation after resolving the reported issue.'});print(json.dumps(result, indent=2));return 1
        finally:
            result.update(root=str(root),micromamba=str(mm),log=str(log),report=str(report_path))
            m.write_json(report_path,result)
            print('Removal result: ' + result['status'] + '\nLog: ' + str(log) + '\nReport: ' + str(report_path), flush=True)
            sys.stdout, sys.stderr = old_out, old_err


def desktop_directory(home, runner=m.run_process):
    if not shutil.which('xdg-user-dir'): return None
    env = os.environ.copy(); env['HOME'] = str(home)
    env['XDG_CONFIG_HOME'] = str(home / '.config')
    result = runner(['xdg-user-dir', 'DESKTOP'], env=env, timeout=10)
    if result.returncode: return None
    target = Path(result.stdout.strip())
    if not target.is_absolute() or target == home or target.is_symlink(): return None
    return target


def desktop_support(runner=m.run_process):
    if 'GNOME' not in os.environ.get('XDG_CURRENT_DESKTOP', '').upper(): return 'Unknown'
    if not shutil.which('gnome-extensions') or not os.environ.get('DBUS_SESSION_BUS_ADDRESS'): return 'Unknown'
    try:
        result = runner(['gnome-extensions', 'list', '--enabled'], timeout=10)
        if result.returncode: return 'Unknown'
        return 'Available' if re.search(r'ding@|desktop-icons@|gtk4-ding@', result.stdout) else 'Unsupported'
    except (OSError, subprocess.SubprocessError): return 'Unknown'


def launcher_validation(desktop, home, runner=m.run_process):
    results = {}
    if shutil.which('desktop-file-validate'):
        value = runner(['desktop-file-validate', desktop], timeout=15)
        results['syntax'] = 'PASS' if value.returncode == 0 else 'FAIL'
        if value.returncode: print(value.stdout + value.stderr)
    else: results['syntax'] = 'SKIP (desktop-file-validate unavailable)'
    if shutil.which('update-desktop-database'):
        value = runner(['update-desktop-database', desktop.parent], timeout=15)
        results['cache'] = 'PASS' if value.returncode == 0 else 'FAIL'
        if value.returncode: print(value.stdout + value.stderr)
    # Gio discovery is stronger evidence than file existence, but does not certify
    # that an interactive GNOME search or launch succeeded.
    probe = '''import gi,json
from gi.repository import Gio
apps=[a for a in Gio.AppInfo.get_all() if a.get_id()=="scientific-python-spyder.desktop"]
print(json.dumps({"found":bool(apps),"visible":bool(apps and apps[0].should_show()),"name":apps[0].get_name() if apps else None}))
'''
    env = os.environ.copy()
    env.update(HOME=str(home), XDG_DATA_HOME=str(home / '.local/share'))
    try:
        value = runner(['/usr/bin/python3', '-c', probe], env=env, timeout=20)
        if value.returncode == 0:
            found = json.loads(value.stdout)
            results['gio_discovery'] = 'PASS' if found['found'] and found['visible'] and found['name'] == 'Scientific Python - Spyder' else 'FAIL'
        else: results['gio_discovery'] = 'SKIP (Gio bindings unavailable)'
    except (OSError, ValueError, subprocess.SubprocessError): results['gio_discovery'] = 'SKIP (Gio discovery unavailable)'
    results['gnome_search_and_launch'] = 'SKIP (requires user graphical acceptance)'
    return results


def current_versions(root, mm):
    installed = m.records(root / 'envs/science')
    values = {name: installed.get(name, {}).get('version', 'not installed') for name in ['python', 'spyder', 'opencv', 'ffmpeg']}
    values['micromamba'] = 'not installed'
    if mm.is_file():
        result = m.run_process([mm, '--version'], timeout=10)
        values['micromamba'] = result.stdout.strip() if not result.returncode else 'unavailable'
    return values


def preflight(mode, root, mm, config, shortcut, validate=False):
    values = current_versions(root, mm)
    installed = m.records(root / 'envs/science')
    action = 'Validation only' if validate else ('Update' if installed else 'Fresh installation')
    print('\nScientific Python Ubuntu V4-r5.2\n' + '=' * 35)
    print('Ubuntu            : ' + platform.freedesktop_os_release().get('VERSION_ID', 'unknown'))
    print('Architecture      : ' + platform.machine())
    print('Operation         : ' + action)
    print('Installation mode : ' + mode)
    print('Micromamba exe    : ' + str(mm))
    print('Micromamba root   : ' + str(root))
    print('Science env       : ' + str(root / 'envs/science'))
    print('GNOME launcher    : ' + str(Path.home() / '.local/share/applications/scientific-python-spyder.desktop'))
    print('Desktop shortcut  : ' + str(shortcut or 'Not requested / Unsupported'))
    print('\n             Current                  Target\n' + '-' * 61)
    configured = {m.spec_name(value): value for value in config['ScientificPackages']}
    for name, target in [('micromamba', config['MicromambaVersion'] + ' (separate approval for version changes)'),
                         ('python', '3.14.x (GIL)'), ('spyder', '6.1.8'), ('opencv', configured['opencv'] + ' (5.x Qt6; no downgrade)'),
                         ('ffmpeg', configured['ffmpeg'] + ' (9.x GPL; no downgrade)')]:
        print('{:12} {:24} {}'.format(name.capitalize(), values[name], target))
    print('The exact resolved target versions will be shown before approval.\n')
    return action


class Tee:
    def __init__(self, terminal, log): self.terminal, self.log = terminal, log
    def write(self, value): self.terminal.write(value); self.log.write(value); self.log.flush()
    def flush(self): self.terminal.flush(); self.log.flush()
    def isatty(self): return self.terminal.isatty()


def diagnostics(root, mm, output, home=None, launcher=None):
    home = Path(home) if home is not None else Path.home()
    report = m.diagnostics(root, output)
    report.update(schema='4-r5', os=platform.freedesktop_os_release().get('PRETTY_NAME'), architecture=platform.machine(),
                  micromamba_root=str(root), micromamba_executable=str(mm), science_environment=str(root / 'envs/science'))
    bashrc = home / '.bashrc'
    text = bashrc.read_text(errors='replace') if bashrc.is_file() else ''
    report['bash_activation'] = {'mamba_hook_present': 'mamba initialize' in text or 'shell hook' in text,
                                 'science_command_path_block': m.PATH_BEGIN.decode() in text}
    report['micromamba_version'] = current_versions(root, mm)['micromamba']
    desktop = home / '.local/share/applications/scientific-python-spyder.desktop'
    report['gnome_launcher'] = launcher or (launcher_validation(desktop, home) if desktop.is_file() else {'status': 'Missing'})
    manifest = root / '.science-launchers.json'
    report['desktop_shortcut'] = json.loads(manifest.read_text()).get('desktop_shortcut', 'Not requested') if manifest.is_file() else 'Unknown'
    # Only allowlisted version/runtime fields; no shell content, environment dump or credentials.
    m.write_json(output, report)
    return report


def run_package_process(argv, env=None, timeout=1800, output=print, interval=5, capture_limit=64 * 1024 * 1024):
    """Drain both streams with bounded buffers while the native child runs."""
    start = time.monotonic()
    process = subprocess.Popen([str(arg) for arg in argv], env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    streams = [bytearray(), bytearray()]; overflow = [False, False]; errors = []

    def drain(source, index):
        try:
            with source:
                for part in iter(lambda: source.read1(65536), b''):
                    remaining = capture_limit - len(streams[index])
                    streams[index].extend(part[:remaining])
                    overflow[index] |= len(part) > remaining
        except OSError as error:
            errors.append(error)

    threads = [threading.Thread(target=drain, args=(pipe, index), daemon=True)
               for index, pipe in enumerate((process.stdout, process.stderr))]
    for thread in threads:
        thread.start()
    try:
        while True:
            elapsed = time.monotonic() - start
            if elapsed >= timeout:
                raise subprocess.TimeoutExpired(argv, timeout)
            try:
                process.wait(timeout=min(interval, timeout - elapsed))
                break
            except subprocess.TimeoutExpired:
                if process.poll() is None and time.monotonic() - start < timeout:
                    elapsed = round(time.monotonic() - start)
                    output('[6/9] Installing packages  RUNNING  Elapsed: {:02}:{:02}  Micromamba process: ACTIVE'.format(*divmod(elapsed, 60)), flush=True)
        for thread in threads:
            thread.join(max(0, min(5, timeout - (time.monotonic() - start))))
        if any(thread.is_alive() for thread in threads) or errors:
            raise m.InstallError('Micromamba output did not close cleanly; transaction result cannot be verified.')
    except BaseException:
        if os.name == 'posix':
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
        elif process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
        if os.name == 'posix':
            # The leader can exit before its post-link children.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
        raise
    out, err = [value.decode('utf-8', 'replace') for value in streams]
    if any(overflow):
        # Retain the native exit code and error. Do not accept partial JSON.
        err += '\nCapture limit exceeded; native exit {}. Transaction output cannot be verified.\n'.format(process.returncode)
        return subprocess.CompletedProcess(argv, process.returncode or 1, '', err)
    return subprocess.CompletedProcess(argv, process.returncode, out, err)


def logged_runner(argv, package_progress=False, **kwargs):
    logfile = getattr(sys.stdout, 'log', None)
    if logfile:
        logfile.write('\nPROCESS: ' + repr([str(a) for a in argv]) + '\n'); logfile.flush()
    value = (run_package_process if package_progress else m.run_process)(argv, **kwargs)
    if logfile:
        logfile.write('EXIT: ' + str(value.returncode) + '\nSTDOUT:\n' + value.stdout + '\nSTDERR:\n' + value.stderr + '\n'); logfile.flush()
    return value


def run_runtime(root, mm):
    output = root / 'science-runtime.json'
    # A stale PASS can never certify a new unsuccessful attempt.
    m.write_json(output, {'status': 'FAIL', 'checks': {}, 'reason': 'Runtime tests have not completed'})
    args = [mm, 'run', '-r', root, '-p', root / 'envs/science', root / 'envs/science/bin/python',
            BUNDLE / 'science-runtime-check.py', '--prefix', root / 'envs/science', '--output', output, '--kernel', '--gui-auto']
    result = logged_runner(args, env=m.isolated_env(root, mm), timeout=1800)
    print(result.stdout, end=''); print(result.stderr, end='', file=sys.stderr)
    report = json.loads(output.read_text())
    if result.returncode or report.get('status') not in ['PASS', 'PENDING']: raise m.InstallError('Runtime tests failed. See runtime report and detailed log.')
    return report


def summary(mode, root, mm, status, runtime, launchers, shortcut, log, report, package_status, other_environments="PENDING"):
    print('\nScientific Python Ubuntu V4-r5.2\n' + '=' * 32)
    print('Installation status: ' + status)
    print('Package installation: ' + package_status)
    print('Automatic tests     : ' + runtime.get('status', 'SKIP'))
    selection=runtime.get('checks',{}).get('packages',{}).get('details',{}).get('package_selection',{})
    if selection:
        print('Requested packages/imports: '+selection['status'])
        print('Release defaults not requested: '+(', '.join(selection['release_not_requested']) or 'none'))
        print('Release defaults not installed: '+(', '.join(selection['release_not_installed']) or 'none'))
    print('Other environments  : ' + other_environments)
    actual_mm = current_versions(root, mm)['micromamba']
    print('Micromamba version  : ' + actual_mm + (' PASS' if actual_mm == m.release()['MicromambaVersion'] else ' PENDING (target 2.10.0)'))
    print('User GUI acceptance : PENDING (GNOME search, Spyder and IPython kernel)')
    print('Installation mode   : ' + mode)
    print('Micromamba exe      : ' + str(mm))
    print('Micromamba root     : ' + str(root))
    print('Science env         : ' + str(root / 'envs/science'))
    values = current_versions(root, mm)
    for name in ['python', 'spyder', 'opencv', 'ffmpeg']:
        status_value = runtime.get('checks', {}).get('packages', {}).get('status', 'SKIP')
        print('{:20}: {} {}'.format(name.capitalize(), values[name], status_value))
    for label, key in [('Python runtime', 'identity'), ('Spyder packages', 'packages'), ('Spyder startup', 'spyder_startup'), ('Fontconfig validation', 'fontconfig_validation'), ('IPython kernel', 'kernel'), ('Video tests', 'videos'), ('OpenCV HighGUI', 'gui')]:
        print('{:20}: {}'.format(label, runtime.get('checks', {}).get(key, {}).get('status', 'SKIP')))
    print('GNOME launcher      : ' + json.dumps(launchers))
    print('Desktop launcher trust: ' + str(launchers.get('desktop_launcher_trust', {}).get('status', 'SKIP')))
    print('Desktop shortcut    : ' + shortcut)
    plan = root / '.science-update-plan.json'
    if plan.is_file(): print('Package changes     : ' + json.dumps(json.loads(plan.read_text()).get('counts', {})))
    print('Log file            : ' + str(log))
    print('Diagnostic report   : ' + str(report))


def select_optional_packages(reader=None, output=print):
    reader = reader or input
    config = m.science_config
    path = config.active_path()
    original = m.safety.read_regular(path)[0]
    value = config.validate(config.read_json(path), BUNDLE)
    if m.safety.read_regular(path)[0] != original:
        raise config.ConfigError('Configuration changed while reading; start again.')
    backend = config.pytorch_backend(value['ScientificPackages'])
    cuda_available = m.has_nvidia_device()
    output('Optional packages')
    output('Configured PyTorch backend: ' + backend.upper())
    output('NVIDIA CUDA device: ' + ('detected; compatibility will be checked by the solver' if cuda_available else 'unavailable'))
    output('1  PyTorch CPU')
    output('2  PyTorch NVIDIA CUDA')
    output('R  Remove the PyTorch request')
    output('Q  Back')
    while True:
        choice = ask('Optional packages: ', 'q', reader).lower()
        if choice in ('1', '2', 'r', 'q'):
            if choice == '2' and not cuda_available:
                output('CUDA requires a working NVIDIA driver and a detectable GPU.')
                continue
            break
        output('Unknown selection.')
    if choice == 'q':
        return False
    if choice == 'r' and ask('Remove the configuration request only? [y/N]: ', 'n', reader).lower() not in ('y', 'yes'):
        return False
    selection = {'1': 'cpu', '2': 'cuda', 'r': 'remove'}[choice]
    backup = config.choose_pytorch_request(BUNDLE, selection, path, expected=original)
    if backup:
        output('Previous package configuration saved to ' + str(backup))
    if selection == 'remove':
        output('PyTorch is no longer requested. Installed packages were preserved.')
        return False
    output('PyTorch ' + selection.upper() + ' selected.')
    output('Installation/update will follow now; no second menu selection is needed. Proposed package changes require separate approval.')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', default='install', choices=['install', 'optional', 'validate', 'diagnostics', 'remove-science', 'remove-root', 'remove-settings', 'remove-total', 'info'])
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    m.verify_bundle()
    home = Path.home(); config = m.release()
    detected = detect(home)
    if args.action == 'info':
        print('Scientific Python Ubuntu V4-r5.2; Ubuntu 24.04/26.04 x86-64')
        print('Default new root: ' + str(home / 'micromamba'))
        print('Science path: <selected root>/envs/science')
        print('Detected roots: ' + json.dumps(detected['roots']))
        print('Detected executable(s): ' + json.dumps(detected['executables']))
        print('Bash activation detected: ' + str(detected['bash_activation']))
        print('Bounded inventory: ' + json.dumps({key: detected[key] for key in ('details', 'unverified_executables', 'registered_external', 'external_cache_settings', 'unknown')}))
        return 0
    if args.action != 'diagnostics': m.platform_guard()
    if args.action == 'optional' and not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise m.InstallError('Optional package selection requires an interactive terminal.')
    step(1, 'PASS')
    if args.action == 'remove-total':
        selection = select_inventory_root(detected, removal=True, total=True)
        return total_remove_action(selection[0], home, detected, selection[2]) if selection[0] else 0
    if args.action == 'diagnostics' or args.action.startswith('remove-'):
        root, mm = select_inventory_root(detected, removal=args.action.startswith('remove-'))
        if root is None:
            return 0
        if mm is None and args.action in ('remove-science', 'diagnostics'):
            if args.action == 'remove-science':
                raise m.InstallError('Science removal requires a verified Micromamba executable association.')
            output = args.output or Path.cwd() / 'science-diagnostics.json'
            m.write_json(output, {'inventory': detected, 'selected_root': str(root), 'runtime': 'SKIPPED: executable association unverified'})
            print('Inventory collected without executing an unverified binary: ' + str(output))
            return 0
        mode = 'Existing'
    else:
        mode, root, mm = select(home, detection=detected, manage_science=False)
    step(2, 'PASS')
    print('Root: {}\nMicromamba executable: {}'.format(root, mm or 'unverified'))
    migration = review_migration(root, home) if args.action in ('install', 'optional') else None
    if args.action in ['install', 'optional', 'validate']:
        try:
            interactive = sys.stdin.isatty() and sys.stdout.isatty()
            if args.action != 'validate' and interactive and not (root / 'envs/science').exists():
                m.science_config.review_new_root_configuration(BUNDLE, root, detected['prior'])
            if migration and migration['format'] == 'ubuntu-lts-v3' and not m.science_config.active_path().exists():
                print('V3 had no saved configuration file. Use the verified archived requests with the current release constraints?')
                if ask('Approve recovery of the V3 package configuration? [y/N]: ', 'n').lower() not in ('y', 'yes'):
                    raise PreparationPending('V3 configuration recovery declined. No environment changes made.')
                m.science_config.recover_v3(BUNDLE, root, m.LEGACY_V3_SPECS, m.history_specs(root / 'envs/science'))
            m.science_config.initialize(BUNDLE, root=root)
            if args.action == 'install':
                m.science_config.offer_release_packages(BUNDLE,interactive=sys.stdin.isatty() and sys.stdout.isatty())
            elif args.action == 'optional':
                if not select_optional_packages():
                    return 0
                args.action = 'install'
            config = m.release()
            m.science_config.require_workflow(config)
            print('Package configuration: ' + str(m.science_config.active_path()))
        except m.science_config.ConfigError as exc:
            raise m.InstallError(str(exc)) from exc
    if args.action == 'diagnostics':
        output = args.output or Path.cwd() / 'science-diagnostics.json'
        report = diagnostics(root, mm, output, home)
        report['inventory'] = detected
        m.write_json(output, report)
        print('Diagnostic collection: SUCCESS. Runtime findings are reported independently.\nReport: ' + str(output)); return 0
    if args.action == 'remove-science':
        return remove_action(root, mm, home)
    if args.action.startswith('remove-'):
        if args.action == 'remove-settings':
            target = m.safety.settings_directory(root, home)
            m.safety.settings_plan(root, home)
            print('Shared ~/.config/spyder-py3 and legacy science Spyder settings are preserved.')
            if ask('Remove owned Spyder settings at {}? [y/N]: '.format(target), 'n').lower() == 'y':
                m.remove_settings(home, root=root)
            return 0
        if args.action == 'remove-root':
            m.root_removal_plan(root, home)
            print('Only the verified installer-owned binary and owned launchers are removal targets.')
            print('Root directory, package cache, user files, environment registries and Bash configuration will be preserved.')
        if ask('Remove {}? [y/N]: '.format(root / 'envs/science' if args.action == 'remove-science' else root / 'bin/micromamba'), 'n').lower() != 'y': return 0
        if args.action == 'remove-science': m.remove_science(root, mm=mm)
        else: m.remove_root(root)
        return 0
    requested = args.action != 'validate' and ask('Create desktop shortcut? [Y/n]: ', 'y').lower() in ['y', 'yes']
    directory = desktop_directory(home) if requested else None
    support = desktop_support() if requested else 'Not requested'
    shortcut = directory / 'scientific-python-spyder.desktop' if directory and support != 'Unsupported' else None
    if requested and support == 'Unsupported': print('Desktop icons are unsupported: the GNOME desktop icons extension is not enabled. The application menu launcher will still be installed.')
    if requested and not directory: print('Desktop shortcut unavailable: xdg-user-dir DESKTOP did not return a usable desktop directory.')
    if shortcut: print('Desktop icons support: ' + support + '. Trust will be applied and read back for this approved launcher; unsupported sessions receive a manual instruction.')
    preflight(mode, root, mm, config, shortcut, args.action == 'validate')
    logdir = home / '.local/state/scientific-python/logs'
    m.safety.plain_path(logdir, missing=True)
    logdir.mkdir(parents=True, exist_ok=True)
    log = logdir / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.log')
    runtime = {}; launchers = {}; package_status = 'SKIP'; result = 'FAIL'; current_step = 3; other_environments = 'PENDING'
    report_path = log.with_suffix('.diagnostics.json')
    shortcut_status = 'Not requested' if not requested else ('Unsupported' if not shortcut else 'Pending')
    old_stdout, old_stderr = sys.stdout, sys.stderr
    with log.open('x', encoding='utf-8') as logfile:
        os.chmod(log, 0o600)
        sys.stdout, sys.stderr = Tee(old_stdout, logfile), Tee(old_stderr, logfile)
        session = contextlib.ExitStack(); session_locked = False
        try:
            if root.exists():
                session.enter_context(m.locked(root)); session_locked = True
            preflight(mode, root, mm, config, shortcut, args.action == 'validate')
            if args.action == 'validate':
                check_micromamba(mm, root, config); step(3, 'PASS')
                step(4, 'SKIP'); step(5, 'SKIP'); step(6, 'SKIP'); step(7, 'SKIP')
                current_step = 8; runtime = run_runtime(root, mm); step(8, runtime.get('status', 'FAIL'))
            else:
                if mode != 'Existing':
                    if ask('Prepare installer-managed Micromamba in this root? [y/N]: ', 'n').lower() != 'y': raise m.InstallError('Preparation was not approved.')
                    m.bootstrap(root, config)
                    if not session_locked:
                        session.enter_context(m.locked(root)); session_locked = True
                mm, actual = ensure_micromamba(mm, root, config, home)
                if mode != 'Existing' and actual != config['MicromambaVersion']: raise m.InstallError('Managed Micromamba must be 2.10.0.')
                print('Micromamba ' + actual + ' compatible; executable preserved.'); step(3, 'PASS')
                current_step = 4; step(4, 'RUNNING')
                if not recheck_usage(root / 'envs/science', 'updated'): raise m.UsageBlocked(m.processes.inspect(root / 'envs/science'), 'updated')
                if migration is not None:
                    m.write_migration_receipt(root, home, mm, migration)
                def progress(number, status):
                    nonlocal current_step
                    current_step = number
                    step(number, status)
                before_others = m.lifecycle.other_environments(root)
                def package_runner(argv, **kwargs):
                    return logged_runner(argv, package_progress=current_step == 6, **kwargs)
                changed = m.sync(root, config, runner=package_runner, mm=mm, existing=mode == 'Existing', progress=progress)
                package_status = 'SUCCESS' if changed else 'Already up to date'
                if not changed: print('Operation: Already up to date (package transaction skipped).')
                previous = m.read_state(root)
                content = m.MARKER + '\ninstaller_version=' + config['InstallerVersion'] + '\nstatus=packages_ready\nmode=' + mode.lower() + '\nmicromamba_exe=' + str(mm) + '\nroot_owned=' + previous.get('root_owned', 'false' if mode == 'Existing' else 'true') + '\n'
                m.atomic_bytes(root / '.scientific-python-installer-state', content.encode(), 0o600)
                index = read_index(home)
                if str(root) not in index: m.write_json(index_file(home), index + [str(root)])
                current_step = 7; step(7, 'RUNNING')
                desktop = m.artifacts(root, mm=mm, desktop_shortcut=shortcut)
                m.profile(root)
                launchers = launcher_validation(desktop, home)
                if any(v == 'FAIL' for v in launchers.values()): raise m.InstallError('Launcher verification failed.')
                if shortcut:
                    trust = m.desktop_tools.trust(shortcut, m.fingerprint(str(root)), approved=True)
                    launchers['desktop_launcher_trust'] = trust
                    shortcut_status = trust['status']
                    if trust['status'] != 'PASS': print(trust.get('reason', '') + '\n' + trust['instruction'])
                m.write_json(root / '.science-launchers.json', {'paths': [str(desktop), str(home / '.local/bin/science-spyder')] + ([str(shortcut)] if shortcut else []), 'desktop_shortcut': shortcut_status})
                step(7, 'PASS'); current_step = 8; step(8, 'RUNNING')
                runtime = run_runtime(root, mm); step(8, runtime.get('status', 'FAIL'))
                after_others = m.lifecycle.other_environments(root)
                other_environments = 'PRESERVED' if before_others == after_others else 'FAIL'
                m.write_json(root / 'science-other-environments.json', {'status': other_environments, 'before_sha256': m.fingerprint(before_others), 'after_sha256': m.fingerprint(after_others), 'scope': 'All other environment paths, sizes/modes/mtime, symlink targets; content hashes of conda metadata. Payload content is not fully rehashed.'})
                if other_environments != 'PRESERVED': raise m.InstallError('Other environment verification changed. No automatic repair of other environments was attempted. Review concurrent activity before retrying.')
                m.mark_complete(root, config, mm=mm, mode=mode, micromamba_version=actual)
                existing = read_index(home)
                if str(root) not in existing: m.write_json(index_file(home), existing + [str(root)])
            current_step = 9; diagnostics(root, mm, report_path, home, launchers)
            if args.action != 'validate' and package_status == 'SUCCESS' and not os.path.lexists(root / m.DEDICATED_ROOT_RECEIPT):
                try:
                    m.seal_dedicated_root(root)
                except (m.InstallError, m.safety.SafetyError, OSError, ValueError) as error:
                    print('Total Remove unavailable for this root: ' + str(error))
            step(9, 'PASS'); result = 'SUCCESS'
        except (m.InstallError, m.safety.SafetyError, OSError, ValueError, subprocess.SubprocessError, EOFError, KeyboardInterrupt) as exc:
            result = 'PENDING' if isinstance(exc, PreparationPending) else 'BLOCKED' if isinstance(exc, (m.UsageBlocked, m.OperationBlocked)) else 'FAIL'
            step(current_step, result); print('ERROR: ' + str(exc), file=sys.stderr)
            file = root / 'science-runtime.json'
            if file.is_file() and current_step == 8: runtime = json.loads(file.read_text())
            try: diagnostics(root, mm, report_path, home, launchers)
            except Exception as report_error: print('Diagnostic collection FAIL: ' + str(report_error), file=sys.stderr)
        finally:
            session.close()
            summary(mode, root, mm, result, runtime, launchers, shortcut_status, log, report_path, package_status, other_environments)
            sys.stdout, sys.stderr = old_stdout, old_stderr
    # The menu remains open. Direct terminal invocations leave the summary visible.
    return 0 if result == 'SUCCESS' else 2 if result in ['PENDING', 'BLOCKED'] else 1


if __name__ == '__main__':
    try: sys.exit(main())
    except (m.InstallError, m.safety.SafetyError, OSError, ValueError, subprocess.SubprocessError, EOFError, KeyboardInterrupt) as exc:
        print('ERROR: ' + str(exc), file=sys.stderr); sys.exit(1)
