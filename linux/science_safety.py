"""Ubuntu deletion primitives: explicit targets, no scripts/cache cleanup, fail closed."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile

PRODUCT = 'scientific-python-ubuntu'


class SafetyError(RuntimeError):
    pass


def plain_path(path, missing=False):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts or any(c in str(path) for c in '\r\n\t\0'):
        raise SafetyError('Unsafe or ambiguous absolute path: ' + str(path))
    for part in [*reversed(path.parents), path]:
        if part.is_symlink():
            raise SafetyError('Directory redirection refused: ' + str(part))
        if not part.exists():
            if missing: break
            raise SafetyError('Required path is missing: ' + str(part))
    return path


@contextlib.contextmanager
def directory_fd(path):
    """Open every component with O_NOFOLLOW; later operations use this anchor."""
    path = plain_path(path)
    if os.name != 'posix' or not hasattr(os, 'O_NOFOLLOW'):
        raise SafetyError('Verified POSIX descriptor operations are required.')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in path.parts[1:]:
            next_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = next_fd
        yield fd
    finally:
        os.close(fd)


def read_regular(path):
    path = plain_path(path)
    with directory_fd(path.parent) as parent:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode): raise SafetyError('Not a regular file: ' + str(path))
            with os.fdopen(fd, 'rb', closefd=False) as stream: content = stream.read()
            return content, (info.st_dev, info.st_ino), info.st_mode & 0o777
        finally: os.close(fd)


def json_regular(path):
    try:
        value = json.loads(read_regular(path)[0])
    except (OSError, ValueError) as exc:
        raise SafetyError('Unreadable/invalid ownership or registry metadata: ' + str(path)) from exc
    if not isinstance(value, dict): raise SafetyError('Expected an ownership object: ' + str(path))
    return value


def file_plan(path):
    content, identity, mode = read_regular(path)
    return {'path': str(path), 'identity': identity, 'sha256': hashlib.sha256(content).hexdigest(), 'mode': mode}


def check_file(plan):
    now = file_plan(Path(plan['path']))
    if now != plan: raise SafetyError('A removal target changed during review: ' + plan['path'])


def unlink_file(plan):
    check_file(plan)
    path = Path(plan['path'])
    with directory_fd(path.parent) as parent:
        info = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if (info.st_dev, info.st_ino) != tuple(plan['identity']) or not stat.S_ISREG(info.st_mode):
            raise SafetyError('Removal target identity changed.')
        os.unlink(path.name, dir_fd=parent)


def mount_points():
    if not Path('/proc/self/mountinfo').is_file(): raise SafetyError('Mount inventory is unavailable.')
    result=[]
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        fields=line.split()
        if len(fields)<6: raise SafetyError('Invalid mount inventory.')
        value=re.sub(r'\\([0-7]{3})',lambda match:chr(int(match[1],8)),fields[4])
        result.append(Path(value))
    return result


def tree_plan(target, dedicated=False, prefixes=()):
    target=plain_path(target)
    if not target.is_dir(): raise SafetyError('Removal target must be a directory.')
    if not getattr(shutil.rmtree,'avoids_symlink_attacks',False):
        raise SafetyError('Symlink-resistant recursive deletion is unavailable.')
    for point in mount_points():
        if point==target or point.is_relative_to(target): raise SafetyError('Mounted directory inside removal target: '+str(point))
    info=target.stat(); snapshot={}
    if dedicated and (info.st_uid != os.getuid() or info.st_mode & 0o022):
        raise SafetyError('The dedicated root is not exclusively under the current user.')
    def failure(error): raise error
    for directory, dirs, files in os.walk(target,followlinks=False,onerror=failure):
        directory=Path(directory)
        # Nested Python/Conda environments are independent data, even under science.
        if 'pyvenv.cfg' in files or (directory!=target and 'conda-meta' in dirs and directory not in prefixes):
            raise SafetyError('Nested Python/Conda environment must be preserved: '+str(directory))
        for name in dirs+files:
            path=directory/name; entry=path.lstat()
            if not (stat.S_ISDIR(entry.st_mode) or stat.S_ISREG(entry.st_mode) or stat.S_ISLNK(entry.st_mode)):
                raise SafetyError('Special file inside removal target: '+str(path))
            if stat.S_ISDIR(entry.st_mode) and entry.st_dev!=info.st_dev:
                raise SafetyError('Filesystem boundary inside removal target.')
            if dedicated:
                if len(snapshot) >= 750000:
                    raise SafetyError('Dedicated root inventory exceeded the entry limit.')
                if entry.st_uid != os.getuid() or (stat.S_ISDIR(entry.st_mode) and entry.st_mode & 0o022):
                    raise SafetyError('Foreign ownership or unsafe directory permissions: '+str(path))
                if stat.S_ISLNK(entry.st_mode) and not path.resolve().is_relative_to(target):
                    raise SafetyError('Link leaves the dedicated root: '+str(path))
            snapshot[str(path.relative_to(target))]=(entry.st_dev,entry.st_ino,entry.st_mode,entry.st_size,entry.st_mtime_ns)
    return {'target':str(target),'identity':(info.st_dev,info.st_ino),'entries':snapshot,'dedicated':dedicated,'prefixes':tuple(prefixes)}


def remove_tree(plan):
    target=Path(plan['target'])
    if tree_plan(target,dedicated=plan.get('dedicated',False),prefixes=plan.get('prefixes',()))!=plan: raise SafetyError('Removal tree changed during review; retry without concurrent writers.')
    with directory_fd(target.parent) as parent:
        info=os.stat(target.name,dir_fd=parent,follow_symlinks=False)
        if (info.st_dev,info.st_ino)!=tuple(plan['identity']) or not stat.S_ISDIR(info.st_mode):
            raise SafetyError('Removal directory identity changed.')
        if plan.get('dedicated'):
            remove_dedicated_entries(parent, target.name, plan)
            return
        # rmtree's fd implementation unlinks leaf symlinks and hardlinks. It does
        # not follow them, chmod shared files, run unlink scripts or clean caches.
        shutil.rmtree(target.name,dir_fd=parent)


def remove_dedicated_entries(parent, name, plan):
    """Never recursively remove files absent from the approved dedicated tree."""
    children = {}
    for key, expected in plan['entries'].items():
        relative = Path(key)
        children.setdefault(relative.parent, {})[relative.name] = expected

    def remove_directory(anchor, basename, relative, identity):
        fd = os.open(basename, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=anchor)
        try:
            st = os.fstat(fd)
            if (st.st_dev, st.st_ino) != tuple(identity):
                raise SafetyError('Directory replaced during deletion: ' + str(relative))
            expected_names = children.get(relative, {})
            if set(os.listdir(fd)) != set(expected_names):
                raise SafetyError('Unapproved directory entry found during deletion: ' + str(relative))
            for child, expected in expected_names.items():
                item = os.stat(child, dir_fd=fd, follow_symlinks=False)
                if (item.st_dev, item.st_ino, item.st_mode, item.st_size, item.st_mtime_ns) != tuple(expected):
                    raise SafetyError('Entry changed during deletion: ' + str(relative / child))
                if stat.S_ISDIR(item.st_mode):
                    remove_directory(fd, child, relative / child, expected[:2])
                else:
                    os.unlink(child, dir_fd=fd)
            st = os.stat(basename, dir_fd=anchor, follow_symlinks=False)
            if not stat.S_ISDIR(st.st_mode) or (st.st_dev, st.st_ino) != tuple(identity):
                raise SafetyError('Directory replaced during deletion: ' + str(relative))
            os.rmdir(basename, dir_fd=anchor)  # Refuses an entry added after enumeration.
        finally:
            os.close(fd)

    remove_directory(parent, name, Path('.'), plan['identity'])


def registry_plan(home, prefix=None, required=False):
    path=Path(home)/'.conda/environments.txt'
    plain_path(path,missing=not required)
    if not path.exists(): return None
    content,identity,mode=read_regular(path)
    try: text=content.decode('utf-8')
    except UnicodeError as exc: raise SafetyError('Environment registry is not valid UTF-8.') from exc
    paths=[]; kept=[]
    for line in text.splitlines(keepends=True):
        value=line.rstrip('\r\n')
        if not value:
            kept.append(line); continue
        item=Path(value)
        if not item.is_absolute() or '..' in item.parts or any(c in value for c in '\0\t\r\n'):
            raise SafetyError('Ambiguous entry in environment registry.')
        paths.append(item)
        if prefix is None or item!=Path(prefix): kept.append(line)
    return {'path':str(path),'identity':identity,'mode':mode,'sha256':hashlib.sha256(content).hexdigest(),
            'paths':paths,'original':content,'new':''.join(kept).encode('utf-8')}


def check_registry(plan):
    if plan is not None:
        content,identity,mode=read_regular(Path(plan['path']))
        if identity!=plan['identity'] or content!=plan['original'] or mode!=plan['mode']:
            raise SafetyError('Environment registry changed during removal review.')


def write_registry(plan):
    if plan is None or plan['new']==plan['original']: return
    check_registry(plan)
    path=Path(plan['path'])
    # Replace only the exact science lines. Keep every other line, order and newline.
    with directory_fd(path.parent) as parent:
        name='.science-registry-'+os.urandom(12).hex()
        fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,plan['mode'],dir_fd=parent)
        try:
            with os.fdopen(fd,'wb') as stream:
                stream.write(plan['new']);stream.flush();os.fsync(stream.fileno())
            fd=None
            check_registry(plan)
            os.replace(name,path.name,src_dir_fd=parent,dst_dir_fd=parent)
        finally:
            if fd is not None:
                try: os.close(fd)
                except OSError: pass
            try: os.unlink(name,dir_fd=parent)
            except FileNotFoundError: pass


def settings_directory(root,home):
    root=Path(root)
    key=hashlib.sha256(str(root).encode()).hexdigest()[:16]
    return Path(home)/'.config/scientific-python'/('spyder-'+key)


def settings_owner(root):
    return {'managed_by':PRODUCT,'scope':'spyder-settings','root':str(root)}


def settings_plan(root,home):
    target=settings_directory(root,home)
    plain_path(target,missing=True)
    if not target.exists(): return None
    owner=json_regular(target/'.science-settings-owner.json')
    if owner!=settings_owner(root): raise SafetyError('Spyder settings are not owned by this installation.')
    return tree_plan(target)


def config_sources(root,home):
    """A custom env-dir configuration makes binary removal unprovable: refuse."""
    root=Path(root);home=Path(home)
    files=[home/'.condarc',home/'.mambarc',home/'.conda/condarc',home/'.conda/.condarc',
           home/'.config/conda/condarc',home/'.config/mamba/mambarc',home/'.config/mamba/.mambarc']
    for base in [root,Path('/etc/conda'),Path('/var/lib/conda')]:
        files += [base/name for name in ['condarc','.condarc','mambarc','.mambarc','condarc.d','mambarc.d']]
    if os.environ.get('XDG_CONFIG_HOME'):
        config=Path(os.environ['XDG_CONFIG_HOME'])
        files += [config/'conda/condarc',config/'conda/condarc.d',config/'mamba/mambarc',config/'mamba/mambarc.d']
    return [str(p) for p in files if os.path.lexists(p)]


def root_inventory(root,home,mm,runner):
    root=plain_path(root);home=plain_path(home);mm=plain_path(mm)
    registry=registry_plan(home,required=True)
    # Missing/invalid registry, non-default env directories or stale entries cannot
    # be replaced by an assumed empty list. They block binary removal entirely.
    if config_sources(root,home): raise SafetyError('Custom Conda/Mamba configuration exists; preserve Micromamba because external env directories are not provably empty.')
    for name in ['CONDA_ENVS_PATH','CONDA_ENVS_DIRS','MAMBA_ENVS_DIRS','CONDARC','MAMBARC']:
        if os.environ.get(name): raise SafetyError('External environment/configuration setting blocks Micromamba removal: '+name)
    if os.environ.get('CONDA_PREFIX') and Path(os.environ['CONDA_PREFIX'])!=root:
        raise SafetyError('An active external environment blocks Micromamba removal.')
    envs=plain_path(root/'envs')
    if not envs.is_dir(): raise SafetyError('Environment directory inventory is unavailable.')
    if any(envs.iterdir()): raise SafetyError('Other environments or unidentified entries remain in envs; Micromamba is preserved.')
    if os.path.lexists(root/'conda-meta') or os.path.lexists(root/'pyvenv.cfg'):
        raise SafetyError('The root itself contains a Python/Conda environment.')
    for item in registry['paths']:
        plain_path(item)
        if item!=root: raise SafetyError('Registered external environment blocks Micromamba removal: '+str(item))
    # env list can clean its registry. Query an exact isolated copy so that the
    # user's registrations are never cleaned or reordered by this read operation.
    with tempfile.TemporaryDirectory(prefix='science-env-inventory-') as temp:
        probe=Path(temp);(probe/'.conda').mkdir();(probe/'.conda/environments.txt').write_bytes(registry['original'])
        env=os.environ.copy()
        for key in list(env):
            if key.startswith(('CONDA_','MAMBA_')) or key in ['PYTHONPATH','PYTHONHOME','CONDARC','MAMBARC']:env.pop(key,None)
        env.update(HOME=str(probe),MAMBA_ROOT_PREFIX=str(root),MAMBA_EXE=str(mm),XDG_CONFIG_HOME=str(probe/'.config'),XDG_CACHE_HOME=str(probe/'.cache'),XDG_DATA_HOME=str(probe/'.local/share'))
        result=runner([mm,'env','list','--json','--no-rc','-r',root],env=env,timeout=30)
        if result.returncode: raise SafetyError('Micromamba environment enumeration failed; nothing was removed.')
        try: data=json.loads(result.stdout)
        except ValueError as exc: raise SafetyError('Micromamba environment list is invalid JSON.') from exc
        if not isinstance(data,dict) or not isinstance(data.get('envs'),list) or not data['envs']:
            raise SafetyError('Micromamba returned no reliable environment inventory.')
        values=data['envs']
        if any(not isinstance(value,str) or not Path(value).is_absolute() for value in values): raise SafetyError('Invalid environment location in Micromamba inventory.')
        if set(values)!={str(root)}: raise SafetyError('Micromamba knows other environments; removal refused.')
        info=runner([mm,'info','--json','--no-rc','-r',root],env=env,timeout=30)
        if info.returncode: raise SafetyError('Micromamba root/locations could not be confirmed.')
        try: data=json.loads(info.stdout)
        except ValueError as exc: raise SafetyError('Micromamba info is invalid JSON.') from exc
        if not isinstance(data,dict) or data.get('base environment')!=str(root) or data.get('envs directories')!=[str(root/'envs')]:
            raise SafetyError('Micromamba root or external environment locations are ambiguous.')
    check_registry(registry)
    if any(envs.iterdir()): raise SafetyError('Environment directory changed during inventory.')
    return registry
