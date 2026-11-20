"""Postconditions and bounded preservation evidence for science-only removal."""
import hashlib
import os
import re
from pathlib import Path
import stat


def tree_metadata(path):
    """No symlink traversal. Content hashes for conda metadata, stats for payloads."""
    path=Path(path)
    if not path.exists():return None
    result={}
    def unreadable(error):raise error
    for directory,dirs,files in os.walk(path,followlinks=False,onerror=unreadable):
        for name in dirs+files:
            file=Path(directory)/name;info=file.lstat();key=str(file.relative_to(path))
            row=[stat.S_IFMT(info.st_mode),stat.S_IMODE(info.st_mode)]
            if file.is_symlink():row+=['link',os.readlink(file)]
            elif file.is_file():
                row+=[info.st_size,info.st_mtime_ns]
                if file.parent.name=='conda-meta':row.append(hashlib.sha256(file.read_bytes()).hexdigest())
            result[key]=row
    return result


def other_environments(root):
    envs=Path(root)/'envs'
    if not envs.is_dir():return {}
    return {path.name:tree_metadata(path) if not path.is_symlink() else ['symlink',os.readlink(path)] for path in envs.iterdir() if path.name!='science'}


def entry_stamp(info):
    # Unlinking a package hardlink in Science legitimately changes the shared
    # inode's link count and ctime without modifying its data or permissions.
    return info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns


def path_stamp(path):
    try:
        return entry_stamp(path.lstat())
    except FileNotFoundError:
        return None


def directory_boundary(path, excluded=(), *, files_only=False):
    """Record the directory identity and immediate entries without following links."""
    try:
        directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None, {}
    try:
        info = os.fstat(directory)
        with os.scandir(directory) as entries:
            children = {entry.name: entry_stamp(entry.stat(follow_symlinks=False))
                        for entry in entries
                        if entry.name not in excluded and not (files_only and entry.is_dir(follow_symlinks=False))}
        # The parent timestamps can change when expected entries are removed.
        return (info.st_dev, info.st_ino, info.st_mode), children
    finally:
        os.close(directory)


def preservation(root,home,mm):
    root = Path(root)
    # The deletion is descriptor-scoped to Science and its approved launchers.
    # Check the boundaries of other resources instead of scanning their payloads.
    owned = {'.science-installer.lock', '.science-env-owner.json', '.science-launchers.json',
             'science-removal.json', 'science-usage.json'}
    return {
        'others': directory_boundary(root / 'envs', {'science'}),
        'cache': directory_boundary(root / 'pkgs'),
        'root_entries': directory_boundary(root, owned, files_only=True),
        'micromamba_sha256': hashlib.sha256(Path(mm).read_bytes()).hexdigest() if Path(mm).is_file() else None,
        'bashrc': path_stamp(Path(home) / '.bashrc'),
    }


def verify(root,home,mm,before,launcher_paths,registry_other_lines,registry_path,runner,env):
    root=Path(root);prefix=root/'envs/science';remaining=[]
    if prefix.exists() or prefix.is_symlink():remaining.append(str(prefix))
    for path in launcher_paths:
        if Path(path).exists() or Path(path).is_symlink():remaining.append(str(path))
    registry=Path(registry_path)
    actual=registry.read_bytes() if registry.is_file() else b''
    registered=any(line.strip()==str(prefix).encode() for line in actual.splitlines())
    if registered:remaining.append(str(registry)+' (science registration)')
    after=preservation(root,home,mm)
    preserved=after==before
    registry_preserved=actual==registry_other_lines
    executable=Path(mm).is_file() and os.access(mm,os.X_OK)
    native={'status':'PENDING','reason':'No executable is available for a native version check.'}
    if executable:
        try:
            value=runner([mm,'--version'],env=env,timeout=15)
            native={'status':'PASS' if value.returncode==0 and bool(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9_.-]+)?',value.stdout.strip())) else 'FAIL','version':value.stdout.strip(),'exit_code':value.returncode}
        except (OSError, __import__('subprocess').SubprocessError) as error:
            native={'status':'FAIL','reason':str(error)}
    return {'status':'PASS' if not remaining and preserved and registry_preserved and native['status']=='PASS' else 'FAIL','science_removed':not prefix.exists(),'science_registration_removed':not registered,'owned_launchers_removed':not any(Path(p).exists() for p in launcher_paths),'remaining_targets':remaining,'other_environments':'PRESERVED' if preserved else 'FAIL','registry_other_lines':'PRESERVED' if registry_preserved else 'FAIL','micromamba':native,'cache_and_user_files':'PRESERVED' if preserved else 'FAIL','preservation_scope':'Directory identities, metadata of sibling environment entries, top-level cache entries and unmanaged root files, Bashrc metadata, Micromamba SHA-256 and exact retained registry lines.','retained_reports':'Installer logs, transaction locks, diagnostics and owned settings are intentionally retained.','instruction':None if not remaining and preserved else 'Do not delete the root or shared cache. Review remaining_targets and the preservation findings before retrying science removal.'}
