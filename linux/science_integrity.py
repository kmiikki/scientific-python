"""Verify immutable installer files, including the shared contract; user JSON is excluded."""
import hashlib
from pathlib import Path
import re

def verify(directory):
    directory=Path(directory).resolve()
    shared=directory/'shared' if (directory/'shared').is_dir() else directory.parent/'shared'
    manifest=directory/'SHA256SUMS.txt'
    if manifest.is_symlink():raise ValueError('Unsafe integrity manifest.')
    names=set()
    for line in manifest.read_text(encoding='ascii').splitlines():
        match=re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_. /-]+)',line)
        if not match:raise ValueError('Invalid immutable manifest entry.')
        digest,name=match.groups()
        if name in names or name=='science-release.json' or '..' in Path(name).parts or Path(name).is_absolute():raise ValueError('Unsafe/duplicate immutable manifest entry: '+name)
        names.add(name)
        base=shared if name.startswith('shared/') else directory
        relative=name[7:] if name.startswith('shared/') else name
        if base.is_symlink():raise ValueError('Redirected immutable resource directory.')
        path=base/relative
        if path.is_symlink() or not path.resolve().is_relative_to(base.resolve()) or not path.is_file():raise ValueError('Missing/unsafe immutable component: '+name)
        # Reject redirected parent components too.
        cursor=path
        while cursor!=base:
            if cursor.is_symlink():raise ValueError('Redirected immutable component: '+name)
            cursor=cursor.parent
        if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:raise ValueError('Installer SHA256 mismatch: '+name)
    mandatory={'science_integrity.py','science_config.py','science-manager.py','science-install.py','science-installer-release.json','shared/science-release.schema.json','shared/science-release.default.json'}
    if not mandatory<=names:raise ValueError('Immutable manifest is incomplete.')
    return True
