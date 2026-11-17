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


def preservation(root,home,mm):
    root=Path(root);home=Path(home)
    envs=root/'envs';others={}
    if envs.is_dir():
        for path in envs.iterdir():
            if path.name!='science':others[path.name]=tree_metadata(path) if not path.is_symlink() else ['symlink',os.readlink(path)]
    # Hash user-owned root-level files; installer reports/reservations are known
    # retained state, not a falsely reported incomplete environment removal.
    owned={'.science-installer.lock','.science-env-owner.json','.science-launchers.json','science-removal.json','science-usage.json'}
    root_files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir() if p.is_file() and not p.is_symlink() and p.name not in owned}
    return {'others':others,'cache':tree_metadata(root/'pkgs'),'root_user_files':root_files,'micromamba_sha256':hashlib.sha256(Path(mm).read_bytes()).hexdigest() if Path(mm).is_file() else None,'bashrc':hashlib.sha256((home/'.bashrc').read_bytes()).hexdigest() if (home/'.bashrc').is_file() else None}


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
    return {'status':'PASS' if not remaining and preserved and registry_preserved and native['status']=='PASS' else 'FAIL','science_removed':not prefix.exists(),'science_registration_removed':not registered,'owned_launchers_removed':not any(Path(p).exists() for p in launcher_paths),'remaining_targets':remaining,'other_environments':'PRESERVED' if preserved else 'FAIL','registry_other_lines':'PRESERVED' if registry_preserved else 'FAIL','micromamba':native,'cache_and_user_files':'PRESERVED' if preserved else 'FAIL','preservation_scope':'All other environment/cache paths, file sizes/modes/mtime and symlink targets; SHA-256 of conda metadata, root-level files, Bashrc and Micromamba. Payloads are not fully rehashed.','retained_reports':'Installer logs, transaction locks, diagnostics and owned settings are intentionally retained.','instruction':None if not remaining and preserved else 'Do not delete the root or shared cache. Review remaining_targets and the preservation findings before retrying science removal.'}
