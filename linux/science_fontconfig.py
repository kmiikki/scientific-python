"""Bounded, recoverable user-cache repair; never run fc-cache as root."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET

CACHE_NAME=re.compile(r'^[0-9a-fA-F]{32}-[A-Za-z0-9_-]+\.cache-[0-9]+$')


def probe(prefix):
    from qtpy import QtGui, QtCore
    # Load the selected platform plugin's ELF dependencies without constructing
    # QApplication or reading the possibly corrupt font caches.
    plugins=Path(QtCore.QLibraryInfo.location(QtCore.QLibraryInfo.PluginsPath))
    platform=os.environ.get('QT_QPA_PLATFORM') or ('xcb' if os.environ.get('DISPLAY') or not os.environ.get('WAYLAND_DISPLAY') else 'wayland')
    filename='libqxcb.so' if platform=='xcb' else 'libqwayland-generic.so' if platform.startswith('wayland') else None
    if filename is None:raise RuntimeError('Unsupported platform for safe fontconfig discovery: '+platform)
    ctypes.CDLL(str(plugins/'platforms'/filename))
    loaded={Path(line.split(maxsplit=5)[-1]).resolve() for line in Path('/proc/self/maps').read_text().splitlines() if len(line.split(maxsplit=5))==6 and 'libfontconfig.so' in line}
    if len(loaded)!=1:raise RuntimeError('Cannot identify the unique fontconfig library loaded by Spyder Qt: '+repr(loaded))
    library=loaded.pop()
    fc=ctypes.CDLL(str(library));fc.FcInitLoadConfig.restype=ctypes.c_void_p
    fc.FcConfigGetCacheDirs.argtypes=[ctypes.c_void_p];fc.FcConfigGetCacheDirs.restype=ctypes.c_void_p
    fc.FcConfigGetFontDirs.argtypes=[ctypes.c_void_p];fc.FcConfigGetFontDirs.restype=ctypes.c_void_p
    fc.FcStrListNext.argtypes=[ctypes.c_void_p];fc.FcStrListNext.restype=ctypes.c_char_p
    fc.FcStrListDone.argtypes=[ctypes.c_void_p];fc.FcConfigDestroy.argtypes=[ctypes.c_void_p]
    config=fc.FcInitLoadConfig()
    if not config:raise RuntimeError('Fontconfig initialization failed.')
    def values(method):
        iterator=method(config);result=[]
        if not iterator:return result
        try:
            while True:
                value=fc.FcStrListNext(iterator)
                if value is None:break
                result.append(os.fsdecode(value))
        finally:fc.FcStrListDone(iterator)
        return result
    try:return {'library':str(library.resolve()),'qt_platform_plugin':str(plugins/'platforms'/filename),'version':fc.FcGetVersion(),'cache_dirs':values(fc.FcConfigGetCacheDirs),'font_dirs':values(fc.FcConfigGetFontDirs)}
    finally:fc.FcConfigDestroy(config)


def supported_crash(value):
    text='\n'.join(str(value.get(key,'')) for key in ['stderr','stdout','native_backtrace','reason'])
    return value.get('segmentation_fault') is True and bool(re.search(r'FcCharSetHasChar|\bFc[A-Z]\w*\s*\(|libfontconfig[^\n]*(?:at|from|\+)|#[0-9]+[^\n]*fontconfig',text,re.I))


def plain_owned_directory(path,home,create=False):
    path=Path(path).absolute();home=Path(home).absolute()
    if path==home or not path.is_relative_to(home):raise RuntimeError('Repair target is outside the user home.')
    for part in [path,*path.parents]:
        if part.is_symlink():raise RuntimeError('Symlinked fontconfig cache/backup directory refused.')
        if part==home:break
    if create:path.mkdir(parents=True,exist_ok=True)
    if not path.is_dir() or path.stat().st_uid!=os.getuid() or path.stat().st_mode&0o002 or (path.stat().st_mode&0o020 and path.stat().st_gid!=os.getgid()):raise RuntimeError('Cache/backup directory ownership or permissions are unsafe.')
    return path


def cache_directory(path,home,prefix,create=False):
    path=Path(path);home=Path(home);prefix=Path(prefix)
    if path==prefix/'var/cache/fontconfig':
        owner=prefix/'.science-owner.json'
        if owner.is_symlink() or not owner.is_file():raise RuntimeError('Science cache needs an owned environment.')
        value=json.loads(owner.read_text())
        if value.get('managed_by')!='scientific-python-ubuntu' or value.get('root')!=str(prefix.parent.parent):raise RuntimeError('Science font cache ownership does not match.')
        return plain_owned_directory(path,prefix,create=create)
    return plain_owned_directory(path,home,create=create)


def repair(prefix,home,diagnostic,state_file,runner=subprocess.run):
    prefix=Path(prefix);home=Path(home);state_file=Path(state_file)
    result={'status':'FAIL','changes':[],'changes_may_have_started':False,'attempts':0,'instruction':'Keep the diagnostic report and cache backup. Retry Validation in a graphical terminal. Do not remove system font caches or change other environments.'}
    if os.geteuid()==0:result['reason']='Automatic font-cache repair refuses root execution.';return result
    if state_file.is_symlink():result['reason']='Symlinked fontconfig repair state refused.';return result
    if state_file.exists():
        previous=json.loads(state_file.read_text())
        if previous.get('attempts',0)>=1:
            result.update(attempts=previous.get('attempts',1),reason='The one automatic repair attempt for this installation has already been used.',backup=previous.get('backup'));return result
    fc=None;match=None
    try:
        number=diagnostic['version'];expected=str(number//10000)+'.'+str(number//100%100)+'.'+str(number%100)
        for candidate in [prefix/'bin/fc-cache',Path('/usr/bin/fc-cache')]:
            peer=candidate.with_name('fc-match')
            if not candidate.is_file() or not peer.is_file():continue
            version=runner([str(candidate),'--version'],capture_output=True,text=True,timeout=20)
            matched_version=runner([str(peer),'--version'],capture_output=True,text=True,timeout=20)
            if version.returncode==0 and matched_version.returncode==0 and expected in version.stdout+version.stderr and expected in matched_version.stdout+matched_version.stderr:
                fc=candidate;match=peer;break
        if fc is None:raise RuntimeError('No fc-cache/fc-match matches the fontconfig library actually loaded by Spyder Qt ('+expected+').')
        cache_home=Path(os.environ.get('XDG_CACHE_HOME',str(home/'.cache')))
        allowed=[cache_home/'fontconfig',home/'.fontconfig',prefix/'var/cache/fontconfig']
        caches=[]
        for name in diagnostic['cache_dirs']:
            path=Path(os.path.expanduser(name))
            if path in allowed:
                if path==prefix/'var/cache/fontconfig' and not path.exists():continue
                caches.append(cache_directory(path,home,prefix,create=True))
            elif path.is_relative_to(home) and path.exists():raise RuntimeError('Nonstandard writable user font cache requires manual review: '+str(path))
        if not caches:raise RuntimeError('No verified user fontconfig cache is used by science.')
        backup=plain_owned_directory(home/'.local/state/scientific-python/fontconfig-backups'/uuid.uuid4().hex,home,create=True)
        manifest=[]
        # Complete preflight of every movable leaf before the first cache change.
        for index,cache in enumerate(caches):
            for path in sorted(cache.iterdir()):
                if not CACHE_NAME.fullmatch(path.name):continue
                info=path.lstat()
                if info.st_uid!=os.getuid() or not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):raise RuntimeError('Foreign or non-file font cache: '+str(path))
                entry={'path':str(path),'backup':str(backup/str(index)/path.name),'mode':stat.S_IMODE(info.st_mode),'identity':[info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns]}
                if path.is_symlink():entry['symlink']=os.readlink(path)
                else:entry['sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
                manifest.append(entry)
        state={'managed_by':'scientific-python-ubuntu','scope':'fontconfig-cache-repair','home':str(home),'prefix':str(prefix),'cache_dirs':[str(c) for c in caches],'status':'RUNNING','attempts':1,'backup':str(backup),'manifest':manifest,'compatible_fc_cache':str(fc),'fontconfig_version':expected}
        (backup/'manifest.json').write_text(json.dumps(state,indent=2)+'\n')
        state_file.write_text(json.dumps(state,indent=2)+'\n');os.chmod(state_file,0o600)
        result.update(attempts=1,backup=str(backup))
        moved=[];applied=[]
        try:
            # Back up all cache leaves without following their symlink targets.
            # Rebuild in private staging while other applications retain their
            # existing shared cache. Only validated cache outputs are installed.
            for entry in manifest:
                path=Path(entry['path']);info=path.lstat()
                if [info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns]!=entry['identity']:raise RuntimeError('Font cache changed concurrently; repair cancelled.')
                target=Path(entry['backup']);target.parent.mkdir(exist_ok=True)
                if 'symlink'in entry:target.symlink_to(entry['symlink'])
                else:shutil.copy2(path,target,follow_symlinks=False)
            staging=backup/'rebuilt-cache';staging.mkdir()
            configuration=ET.Element('fontconfig')
            for name in diagnostic['font_dirs']:ET.SubElement(configuration,'dir').text=name
            ET.SubElement(configuration,'cachedir').text=str(staging)
            config=backup/'rebuild-fonts.conf';ET.ElementTree(configuration).write(config,encoding='utf-8',xml_declaration=True)
            env=os.environ.copy();env.update(HOME=str(home),FONTCONFIG_FILE=str(config),FONTCONFIG_PATH=str(backup))
            outcome=runner([str(fc),'--force','--verbose'],env=env,capture_output=True,text=True,timeout=180)
            (backup/'fc-cache.log').write_text(outcome.stdout+'\n'+outcome.stderr)
            if outcome.returncode:raise RuntimeError('Compatible fc-cache failed (exit '+str(outcome.returncode)+').')
            matched=runner([str(match),'sans'],env=env,capture_output=True,text=True,timeout=30)
            if matched.returncode:raise RuntimeError('Font matching still fails after cache rebuild.')
            generated=[p for p in staging.iterdir() if CACHE_NAME.fullmatch(p.name) and not p.is_symlink()]
            state['compatibility_symlinks_not_installed']=[p.name for p in staging.iterdir() if p.is_symlink()]
            if not generated:raise RuntimeError('fc-cache did not produce any verifiable cache file.')
            for path in generated:
                if path.is_symlink() or not path.is_file() or path.stat().st_uid!=os.getuid():raise RuntimeError('Unsafe rebuilt cache file.')
            for entry in manifest:
                path=Path(entry['path']);info=path.lstat()
                if [info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns]!=entry['identity']:raise RuntimeError('Shared cache changed during rebuild; nothing else is overwritten.')
            result['changes_may_have_started']=True
            for entry in manifest:
                Path(entry['path']).unlink();moved.append(entry)
            for cache in caches:
                for source in generated:
                    target=cache/source.name
                    if target.exists() or target.is_symlink():raise RuntimeError('Another application created a font cache concurrently.')
                    fd,temporary=tempfile.mkstemp(dir=cache,prefix='.science-font-');os.close(fd)
                    try:
                        shutil.copyfile(source,temporary);os.chmod(temporary,0o644);os.replace(temporary,target)
                    finally:
                        if os.path.exists(temporary):os.unlink(temporary)
                    applied.append((target,hashlib.sha256(source.read_bytes()).hexdigest()))
            state['generated_records']=[{'path':str(path),'sha256':digest} for path,digest in applied]
            state.update(status='REBUILT',rebuild_command=[str(fc),'--force','--verbose'])
            result.update(status='REBUILT',attempts=1,backup=str(backup),changes=[str(p) for p in caches],reason='User cache rebuilt; Spyder startup must pass before repair is certified.',instruction=None)
        except BaseException:
            state['status']='ROLLBACK_PENDING'
            for path,digest in applied:
                if path.is_file() and not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest()==digest:path.unlink()
            for entry in moved:
                path=Path(entry['path'])
                if path.exists() or path.is_symlink():raise RuntimeError('Shared cache changed during rollback; backup retained for manual recovery.')
                if 'symlink'in entry:path.symlink_to(entry['symlink'])
                else:shutil.copy2(entry['backup'],path,follow_symlinks=False)
            state['status']='ROLLED_BACK';raise
        finally:
            state_file.write_text(json.dumps(state,indent=2)+'\n')
            (backup/'manifest.json').write_text(json.dumps(state,indent=2)+'\n')
    except (OSError,ValueError,KeyError,RuntimeError,subprocess.SubprocessError) as error:
        result.update(reason=str(error),attempts=1 if state_file.exists() else 0)
        if state_file.exists():
            try:result['rollback_status']=json.loads(state_file.read_text()).get('status')
            except (OSError,ValueError):pass
    return result


def restore(backup,home,approved=False):
    home=Path(home).absolute();backup=plain_owned_directory(backup,home)
    base=home/'.local/state/scientific-python/fontconfig-backups'
    if backup.parent!=base:raise RuntimeError('Backup is outside the managed font-cache backup directory.')
    manifest=backup/'manifest.json'
    if manifest.is_symlink() or manifest.stat().st_uid!=os.getuid():raise RuntimeError('Foreign backup manifest.')
    state=json.loads(manifest.read_text())
    if state.get('managed_by')!='scientific-python-ubuntu' or state.get('scope')!='fontconfig-cache-repair' or state.get('home')!=str(home):raise RuntimeError('Backup ownership does not match the selected home.')
    caches=[cache_directory(name,home,Path(state['prefix'])) for name in state['cache_dirs']]
    generated={}
    for record in state.get('generated_records',[]):
        path=Path(record['path'])
        if path.parent not in caches or not CACHE_NAME.fullmatch(path.name):raise RuntimeError('Generated cache path escapes its owned directory.')
        if path.exists() or path.is_symlink():
            if path.is_symlink() or not path.is_file() or path.stat().st_uid!=os.getuid() or hashlib.sha256(path.read_bytes()).hexdigest()!=record['sha256']:raise RuntimeError('A rebuilt cache changed after repair; automatic restoration refuses to overwrite another application.')
            generated[path]=record['sha256']
    for record in state['manifest']:
        path=Path(record['path']);saved=Path(record['backup'])
        if path.parent not in caches or not CACHE_NAME.fullmatch(path.name) or saved.parent.parent!=backup or saved.name!=path.name:raise RuntimeError('Backup path escapes its recorded cache.')
        if 'symlink'in record:
            if not saved.is_symlink() or os.readlink(saved)!=record['symlink']:raise RuntimeError('Backup symlink differs from its recorded value.')
        elif saved.is_symlink() or hashlib.sha256(saved.read_bytes()).hexdigest()!=record['sha256']:raise RuntimeError('Backup SHA-256 differs.')
        if (path.exists() or path.is_symlink()) and path not in generated:
            same=(path.is_symlink() and 'symlink'in record and os.readlink(path)==record['symlink']) or (not path.is_symlink() and path.is_file() and 'sha256'in record and hashlib.sha256(path.read_bytes()).hexdigest()==record['sha256'])
            if not same:raise RuntimeError('An original cache path is now used by another cache; no restoration has started.')
    if not approved:return {'status':'PENDING','targets':[r['path'] for r in state['manifest']],'instruction':'Confirm restoration only after closing font-using applications. No system cache is a target.'}
    for path in generated:path.unlink()
    for record in state['manifest']:
        path=Path(record['path'])
        if path.exists() or path.is_symlink():continue
        if 'symlink'in record:path.symlink_to(record['symlink'])
        else:shutil.copy2(record['backup'],path,follow_symlinks=False)
    state['restore_status']='PASS';manifest.write_text(json.dumps(state,indent=2)+'\n')
    return {'status':'PASS','reason':'Original user-cache leaves restored from verified backups. Unrelated files and system caches were preserved.'}


if __name__=='__main__':
    parser=argparse.ArgumentParser();group=parser.add_mutually_exclusive_group(required=True);group.add_argument('--probe',type=Path);group.add_argument('--restore-backup',type=Path);parser.add_argument('--home',type=Path,default=Path.home());parser.add_argument('--yes',action='store_true');args=parser.parse_args()
    if args.probe:print(json.dumps(probe(args.probe)))
    else:
        plan=restore(args.restore_backup,args.home);print(json.dumps(plan,indent=2))
        approved=args.yes or input('Restore only these backed-up user font caches? [y/N]: ').strip().lower()=='y'
        if approved:print(json.dumps(restore(args.restore_backup,args.home,approved=True),indent=2))
