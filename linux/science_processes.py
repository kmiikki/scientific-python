"""Read-only Linux usage evidence and science-only Bash activation leases."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile

PRODUCT='scientific-python-ubuntu'


def within(value,prefix):
    try:return Path(value.removesuffix(' (deleted)')).is_absolute() and Path(value.removesuffix(' (deleted)')).is_relative_to(prefix)
    except (TypeError,ValueError):return False


def process_identity(process):
    text=(process/'stat').read_text();tail=text[text.rfind(')')+2:].split()
    return {'start':tail[19],'state':tail[0],'uid':process.stat().st_uid}


def shell_state(prefix,pid,active,proc=Path('/proc')):
    prefix=Path(prefix).absolute();root=prefix.parent.parent
    if prefix.name!='science':raise RuntimeError('Only science activation is tracked.')
    owner=json.loads((prefix/'.science-owner.json').read_text())
    if owner.get('managed_by')!=PRODUCT or owner.get('root')!=str(root):raise RuntimeError('Unowned prefix')
    directory=root/'.science-shells'
    for path in [directory,*directory.parents]:
        if path.is_symlink():raise RuntimeError('Symlinked shell-state directory')
    directory.mkdir(exist_ok=True)
    if directory.stat().st_uid!=os.getuid():raise RuntimeError('Foreign shell-state directory')
    identity=process_identity(Path(proc)/str(pid))
    if identity['uid']!=os.getuid():raise RuntimeError('Foreign shell process')
    command=(Path(proc)/str(pid)/'comm').read_text().strip()
    if command not in ['bash','-bash']:raise RuntimeError('Only a live Bash shell can hold an activation lease.')
    value=dict(identity,managed_by=PRODUCT,prefix=str(prefix),pid=pid,active=bool(active))
    target=directory/(str(pid)+'.json')
    if target.is_symlink():raise RuntimeError('Symlinked shell-state file')
    fd,temporary=tempfile.mkstemp(dir=directory,prefix='.lease-')
    try:
        with os.fdopen(fd,'w') as stream:json.dump(value,stream);stream.write('\n')
        os.chmod(temporary,0o600);os.replace(temporary,target)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)


def leases(prefix,proc):
    result={};warnings=[];directory=prefix.parent.parent/'.science-shells'
    if not directory.exists():return result,warnings
    if directory.is_symlink() or directory.stat().st_uid!=os.getuid():return {},['Shell activation state cannot be trusted.']
    for path in directory.glob('*.json'):
        try:
            if path.is_symlink() or path.stat().st_uid!=os.getuid():raise ValueError('Foreign lease')
            value=json.loads(path.read_text());pid=int(path.stem)
            if value.get('managed_by')!=PRODUCT or value.get('prefix')!=str(prefix) or value.get('pid')!=pid:raise ValueError('Invalid lease')
            process=proc/str(pid)
            if not process.exists():continue  # A dead shell's record is inert; no unlink race.
            identity=process_identity(process)
            if (process/'comm').read_text().strip() not in ['bash','-bash']:continue
            if value.get('uid')==identity['uid'] and value.get('start')==identity['start'] and identity['state']!='Z':result[pid]=value['active']
        except FileNotFoundError:continue
        except (OSError,ValueError,KeyError):warnings.append('Unverifiable shell activation record: '+path.name)
    return result,warnings


def inspect(prefix,env=None,proc=Path('/proc'),own_pid=None):
    prefix=Path(prefix).absolute();env=os.environ if env is None else env;proc=Path(proc);own_pid=os.getpid() if own_pid is None else own_pid
    blocked=[];observations=[];activation=env.get('CONDA_PREFIX')
    if prefix.exists() and activation and Path(activation).absolute()==prefix:
        blocked.append({'kind':'current_shell','pid':os.getppid(),'application':'calling shell','evidence':['CONDA_PREFIX matches science'],'action':'Run micromamba deactivate in the calling terminal, then start this operation again.'})
    active_leases,warnings=leases(prefix,proc)
    if not proc.is_dir():warnings.append('Linux /proc is unavailable; process usage cannot be verified.')
    for process in proc.glob('[0-9]*'):
        pid=int(process.name)
        if pid==own_pid:continue
        try:
            identity=process_identity(process)
            if identity['uid']!=os.getuid() or identity['state']=='Z':continue
            name=(process/'comm').read_text().strip();evidence=[];unreadable=[]
            if active_leases.get(pid):evidence.append('verified active Bash lease')
            try:
                if within(os.readlink(process/'cwd'),prefix):evidence.append('working directory in selected prefix')
            except (FileNotFoundError,PermissionError):pass
            try:
                executable=os.readlink(process/'exe')
                if within(executable,prefix):evidence.append('executable in science')
            except FileNotFoundError:continue
            except PermissionError:unreadable.append('executable')
            try:
                maps=(process/'maps').read_text(errors='replace')
                if any(within(line.split(maxsplit=5)[-1],prefix) for line in maps.splitlines() if len(line.split(maxsplit=5))==6):evidence.append('mapped science library/file')
            except FileNotFoundError:continue
            except PermissionError:unreadable.append('memory maps')
            try:
                for fd in (process/'fd').iterdir():
                    try:
                        target=os.readlink(fd)
                        if within(target,prefix):evidence.append('open prefix file or directory');break
                    except FileNotFoundError:continue
            except FileNotFoundError:continue
            except PermissionError:unreadable.append('file descriptors')
            if unreadable:
                # Access-restricted system/desktop helpers are not evidence of
                # science usage. If their argv actually references science,
                # inability to inspect it is an actionable blocker.
                try:
                    arguments=(process/'cmdline').read_bytes().split(b'\0')
                    if any(within(os.fsdecode(arg),prefix) for arg in arguments if arg):evidence.append('science path in process arguments; restricted inspection')
                except (FileNotFoundError,PermissionError):pass
                observations.append({'pid':pid,'application':name,'reason':'Restricted '+', '.join(unreadable)+'; no unrelated process is terminated.'})
            if not evidence:
                try:
                    entries=(process/'environ').read_bytes().split(b'\0')
                    if ('CONDA_PREFIX='+str(prefix)).encode() in entries and pid not in active_leases:
                        observations.append({'pid':pid,'application':name,'reason':'Inherited science environment marker; no executable, mapping, file or live activation lease confirms use.'})
                except (PermissionError,FileNotFoundError):pass
            if evidence:blocked.append({'kind':'process','pid':pid,'application':name,'evidence':evidence,'action':'Deactivate science in this terminal.' if 'verified active Bash lease' in evidence else 'Close this application or kernel normally, then recheck.'})
        except FileNotFoundError:continue
        except (PermissionError,OSError,ValueError,IndexError):
            if process.exists():observations.append({'pid':pid,'application':'unavailable','reason':'Process disappeared or changed permissions during inspection; no confirmed science reference.'})
    return {'status':'BLOCKED' if blocked or warnings else 'PASS','prefix':str(prefix),'blockers':blocked,'uncertainties':warnings,'observations':observations,'no_user_processes_terminated':True}


def guidance(report,operation='modify'):
    lines=['Science environment cannot be '+operation+'.','No package or environment files have been changed by this operation.']
    for blocker in report['blockers']:
        lines+=['PID {pid}  {application}: '.format(**blocker)+', '.join(blocker['evidence']),blocker['action']]
    lines+=report['uncertainties']
    lines+=['Other environments must remain open/unchanged; close only the listed science users.','Choose Recheck after resolving the listed reason. A child installer cannot deactivate its calling shell.']
    return '\n'.join(lines)


def hook_text(prefix,support,active):
    import shlex
    return ('# Scientific Python science activation tracking\n/usr/bin/python3 '+shlex.quote(str(support/'science_processes.py'))+' --shell-state '+shlex.quote(str(prefix))+' --pid "${BASHPID:-$$}" '+('--active' if active else '--inactive')+' || printf "Science activation tracking failed; use installer diagnostics.\\n" >&2\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--shell-state',type=Path,required=True);parser.add_argument('--pid',type=int,required=True);parser.add_argument('--active',action='store_true');parser.add_argument('--inactive',action='store_true');args=parser.parse_args()
    shell_state(args.shell_state,args.pid,args.active)
