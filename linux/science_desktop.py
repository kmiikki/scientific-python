"""Trust only an approved, owned GNOME desktop entry; preserve inode on updates."""
import configparser
import os
from pathlib import Path
import shutil
import stat
import subprocess


def validate(path,root_id):
    path=Path(path)
    for part in [path,*path.parents]:
        if part.is_symlink():raise RuntimeError('Symlinked desktop path refused.')
    info=path.stat()
    if info.st_uid!=os.getuid() or not stat.S_ISREG(info.st_mode):raise RuntimeError('Desktop entry is not a user-owned regular file.')
    if info.st_mode & 0o002 or path.parent.stat().st_mode & 0o002 or (info.st_mode & 0o020 and info.st_gid != os.getgid()):raise RuntimeError('Desktop entry/directory is writable by another account.')
    parser=configparser.ConfigParser(interpolation=None,strict=True);parser.optionxform=str;parser.read_string(path.read_text())
    entry=parser['Desktop Entry']
    if entry.get('Type')!='Application' or entry.get('Name')!='Scientific Python - Spyder' or entry.get('X-Scientific-Python-Managed')!='true' or entry.get('X-Scientific-Python-Root-Id')!=root_id or not entry.get('Exec'):
        raise RuntimeError('Desktop entry ownership or syntax does not match this installation.')
    return info


def trust(path,root_id,approved=False,runner=subprocess.run,env=None):
    env=os.environ.copy() if env is None else dict(env)
    result={'status':'PENDING','path':str(path),'instruction':'Right-click this desktop icon → Allow Launching. No GNOME global setting was changed.'}
    if not approved:
        result['reason']='Desktop shortcut creation was not approved.';return result
    try:
        info=validate(path,root_id)
        if shutil.which('desktop-file-validate',path=env.get('PATH')):
            check=runner(['desktop-file-validate',str(path)],capture_output=True,text=True,env=env,timeout=15)
            if check.returncode:raise RuntimeError('Desktop Entry validator rejected the launcher: '+check.stderr)
        os.chmod(path,stat.S_IMODE(info.st_mode)|0o100)
        if 'GNOME' not in env.get('XDG_CURRENT_DESKTOP','').upper() or not env.get('DBUS_SESSION_BUS_ADDRESS'):
            result['reason']='GNOME user metadata service is unavailable in this session.';return result
        if not shutil.which('gio',path=env.get('PATH')):
            result['reason']='gio is unavailable.';return result
        def query():return runner(['gio','info','-a','metadata::trusted',str(path)],capture_output=True,text=True,env=env,timeout=15)
        current=query()
        if current.returncode or 'metadata::trusted: true' not in current.stdout:
            change=runner(['gio','set',str(path),'metadata::trusted','true'],capture_output=True,text=True,env=env,timeout=15)
            if change.returncode:
                result['reason']='GIO trust write failed: '+change.stderr.strip();return result
        current=query();validate(path,root_id)
        if current.returncode or 'metadata::trusted: true' not in current.stdout:
            result['reason']='GIO did not confirm trust metadata.';return result
        result.update(status='PASS',metadata_trusted=True,executable=os.access(path,os.X_OK),instruction=None)
        if not result['executable']:result.update(status='FAIL',reason='Executable bit verification failed.')
    except (OSError,ValueError,configparser.Error,RuntimeError,subprocess.SubprocessError) as error:
        result.update(reason=str(error))
    return result


def write_entry(path,content,mode,atomic_writer):
    """GIO metadata is inode-sensitive: preserve the existing inode if unchanged.

    For changed owned entries keep their inode and restore original bytes on a
    write failure. The caller has already validated the managed ownership marker.
    A subsequent trust read/write confirms the actual GNOME state.
    """
    path=Path(path)
    if not path.exists():atomic_writer(path,content,mode);return
    if path.is_symlink() or path.stat().st_uid!=os.getuid():raise RuntimeError('Foreign desktop file')
    old=path.read_bytes();old_mode=stat.S_IMODE(path.stat().st_mode)
    if old==content:
        os.chmod(path,mode);return
    fd=os.open(path,os.O_WRONLY|os.O_NOFOLLOW)
    try:
        try:
            with os.fdopen(os.dup(fd),'wb',closefd=True) as stream:
                stream.write(content);stream.truncate();stream.flush();os.fsync(stream.fileno())
            os.fchmod(fd,mode)
        except BaseException:
            os.lseek(fd,0,os.SEEK_SET);os.write(fd,old);os.ftruncate(fd,len(old));os.fchmod(fd,old_mode);os.fsync(fd);raise
    finally:os.close(fd)
