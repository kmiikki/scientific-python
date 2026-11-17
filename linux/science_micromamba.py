"""Approved, reversible per-user executable promotion; never solve packages."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import tarfile
import tempfile
import uuid
import urllib.request

BEGIN='# >>> scientific-python Micromamba >>>'
END='# <<< scientific-python Micromamba <<<'


def plain(path,home):
    path=Path(path)
    if not path.is_absolute() or not path.is_relative_to(home) or path==home:raise RuntimeError('A promotion target must be inside the selected user home.')
    for part in [path,*path.parents]:
        if part.is_symlink():raise RuntimeError('Symlinked Micromamba/shell configuration path refused.')
        if part==home:break
    if path.exists() and (not path.is_file() or path.stat().st_uid!=os.getuid()):raise RuntimeError('A promotion target is not a user-owned regular file: '+str(path))


def snapshot(root,home):
    root=Path(root);home=Path(home)
    data={'env_names':sorted(p.name for p in (root/'envs').iterdir()) if (root/'envs').is_dir() else [],'files':{}}
    metadata=list(root.glob('envs/*/conda-meta/*.json'))+list(root.glob('envs/*/conda-meta/history'))
    registry=home/'.conda/environments.txt'
    if registry.is_file():
        for line in registry.read_text().splitlines():
            value=line.strip()
            if not value:continue
            prefix=Path(value)
            if not prefix.is_absolute():raise RuntimeError('A relative registry entry prevents safe promotion verification.')
            if (prefix/'conda-meta').is_dir():metadata+=list((prefix/'conda-meta').glob('*.json'))+[prefix/'conda-meta/history']
    for file in metadata+[registry]:
        if file.is_symlink():raise RuntimeError('Environment/registry symlink prevents promotion verification.')
        if file.is_file():data['files'][str(file)]=hashlib.sha256(file.read_bytes()).hexdigest()
    cache=root/'pkgs'
    data['cache']={p.name:[p.lstat().st_mode,p.lstat().st_size,p.lstat().st_mtime_ns] for p in cache.iterdir()} if cache.is_dir() else {}
    return data


def block(text,hook):
    if text.count(BEGIN)!=text.count(END) or text.count(BEGIN)>1:raise RuntimeError('Ambiguous managed Bash block; existing settings preserved.')
    if BEGIN in text:text=text[:text.index(BEGIN)]+text[text.index(END)+len(END):]
    return text.rstrip()+'\n\n'+BEGIN+'\nif [ -n "${BASH_VERSION:-}" ]; then\n    . '+shlex.quote(str(hook))+'\nfi\n'+END+'\n'


def promote(home,root,old,config,manager,runner=None,fetch=None):
    """Caller obtains explicit upgrade approval before invoking this mutation."""
    m=manager;runner=runner or m.run_process;home=Path(home);root=Path(root);old=Path(old)
    m.guard_root(root, home, existing=True)
    m.safety.plain_path(home)
    if os.geteuid()==0:raise m.InstallError('Use a normal user account; Micromamba promotion never needs sudo.')
    target=home/'.local/bin/micromamba';support=home/'.local/share/scientific-python';hook=support/'micromamba-shell.sh';owner=support/'micromamba-owner.json'
    login=next((home/name for name in ['.bash_profile','.bash_login','.profile'] if (home/name).exists()),home/'.profile')
    paths=list(dict.fromkeys([target,hook,owner,home/'.bashrc',login]))
    for path in paths:plain(path,home)
    before=snapshot(root,home);backup=home/'.local/state/scientific-python/micromamba-backups'/uuid.uuid4().hex
    for part in [backup,*backup.parents]:
        if part.is_symlink():raise m.InstallError('Symlinked upgrade backup directory refused.')
        if part==home:break
    backup.mkdir(parents=True,mode=0o700)
    preserved={}
    for index,path in enumerate(paths):
        if path.exists():
            saved=backup/(str(index)+'.backup');shutil.copy2(path,saved);preserved[str(path)]={'backup':str(saved),'mode':stat.S_IMODE(path.stat().st_mode)}
        else:preserved[str(path)]=None
    (backup/'manifest.json').write_text(json.dumps({'managed_by':'scientific-python-ubuntu','root':str(root),'previous_executable':str(old),'files':preserved},indent=2)+'\n')
    result={'status':'FAIL','target':str(target),'backup':str(backup),'package_transactions':0,'other_environments':'PENDING'}
    changed=[]
    def execute(argv,env=None,timeout=30):
        value=runner(argv,env=env,timeout=timeout)
        if value.returncode:raise m.InstallError('Micromamba promotion check failed: '+str(argv[1:])+'\n'+value.stderr)
        return value.stdout
    try:
        candidate=backup/'candidate-micromamba'
        if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest()==config['MicromambaExeSha256']:
            shutil.copyfile(target,candidate)
        elif old.is_file() and hashlib.sha256(old.read_bytes()).hexdigest()==config['MicromambaExeSha256']:
            shutil.copyfile(old,candidate)
        else:
            archive=backup/'micromamba.tar.bz2'
            url='https://github.com/mamba-org/micromamba-releases/releases/download/'+config['MicromambaRelease']+'/'+config['MicromambaArchive']
            if fetch:fetch(url,archive)
            else:
                with urllib.request.urlopen(url,timeout=120) as response,archive.open('wb') as stream:shutil.copyfileobj(response,stream)
            if hashlib.sha256(archive.read_bytes()).hexdigest()!=config['MicromambaArchiveSha256']:raise m.InstallError('Micromamba archive SHA-256 mismatch; old executable/settings preserved.')
            with tarfile.open(archive,'r:bz2') as package:
                item=package.getmember('bin/micromamba')
                if not item.isfile():raise m.InstallError('Micromamba archive executable is not a regular file.')
                with package.extractfile(item) as stream,candidate.open('wb') as output:shutil.copyfileobj(stream,output)
        if hashlib.sha256(candidate.read_bytes()).hexdigest()!=config['MicromambaExeSha256']:raise m.InstallError('Micromamba executable SHA-256 mismatch.')
        candidate.chmod(0o755)
        probe_home=backup/'probe-home';probe_home.mkdir();(probe_home/'.conda').mkdir()
        registry=home/'.conda/environments.txt'
        if registry.is_file():shutil.copyfile(registry,probe_home/'.conda/environments.txt')
        env=m.isolated_env(root,candidate,probe_home)
        env.update(XDG_CONFIG_HOME=str(probe_home/'.config'),XDG_DATA_HOME=str(probe_home/'.local/share'),XDG_CACHE_HOME=str(probe_home/'.cache'))
        if execute([candidate,'--version'],env).strip()!=config['MicromambaVersion']:raise m.InstallError('Wrong candidate Micromamba version.')
        old_list=json.loads(execute([old,'env','list','--no-rc','--json','-r',root],env))
        new_list=json.loads(execute([candidate,'env','list','--no-rc','--json','-r',root],env))
        if set(old_list.get('envs',[]))!=set(new_list.get('envs',[])) or not new_list.get('envs'):raise m.InstallError('Candidate sees a different environment list.')
        info=json.loads(execute([candidate,'info','--no-rc','--json','-r',root],env))
        reported=info.get('base environment') or info.get('root_prefix')
        if reported!=str(root):raise m.InstallError('Candidate changed the selected root.')
        checked=[]
        targets={root/'envs'/name for name in before['env_names']} | {Path(value) for value in new_list['envs'] if value!=str(root)}
        for prefix in sorted(targets):
            name=str(prefix)
            if not (prefix/'conda-meta').is_dir():raise m.InstallError('Unidentified environment directory requires manual review: '+name)
            script=execute([candidate,'shell','activate','--no-rc','-s','bash','-p',prefix],env)
            if str(prefix) not in script or 'CONDA_PREFIX' not in script:raise m.InstallError('Activation output does not identify '+name)
            check=backup/'activation-check.sh';check.write_text(script);execute(['bash','-n',check],env);checked.append(name)
        shell='''# Scientific Python user-managed Micromamba selection\n'''
        shell+='export MAMBA_EXE='+shlex.quote(str(target))+'\nexport MAMBA_ROOT_PREFIX='+shlex.quote(str(root))+'\n'
        shell+='export PATH='+shlex.quote(str(target.parent))+':"$PATH"\nhash -r\n'
        shell+='eval "$("$MAMBA_EXE" shell hook --no-rc --shell bash --root-prefix "$MAMBA_ROOT_PREFIX")"\n'
        contents={target:candidate.read_bytes(),hook:shell.encode(),owner:(json.dumps({'managed_by':'scientific-python-ubuntu','root':str(root),'executable':str(target),'sha256':config['MicromambaExeSha256'],'backup':str(backup)},indent=2)+'\n').encode()}
        for path in [home/'.bashrc',login]:contents[path]=block(path.read_text() if path.exists() else '',hook).encode()
        for path in contents:
            saved=preserved[str(path)]
            plain(path,home)
            if saved:
                if not path.is_file() or path.read_bytes()!=Path(saved['backup']).read_bytes() or stat.S_IMODE(path.stat().st_mode)!=saved['mode']:
                    raise m.InstallError('A user configuration changed during preparation; the concurrent edit is retained: '+str(path))
            elif path.exists():raise m.InstallError('A previously absent selection file was created concurrently; it is retained: '+str(path))
        for path,data in contents.items():
            plain(path,home);m.atomic_bytes(path,data,0o755 if path==target else preserved.get(str(path),{}).get('mode',0o644) if preserved.get(str(path)) else 0o644);changed.append(path)
        # Source the actual per-user rc and selected login profile in bounded
        # fresh Bash children. The caller's already-running shell is untouched.
        selection='''test "$MAMBA_EXE" = '''+shlex.quote(str(target))+''' && test "$MAMBA_ROOT_PREFIX" = '''+shlex.quote(str(root))+''' && test "$(micromamba --version)" = '''+shlex.quote(config['MicromambaVersion'])+''' && test "$(type -P micromamba)" = '''+shlex.quote(str(target))+'''\n'''
        shell_env=os.environ.copy()
        for key in list(shell_env):
            if key.startswith(('CONDA_','MAMBA_','BASH_FUNC_')):shell_env.pop(key,None)
        shell_env.update(HOME=str(home),PATH=str(old.parent)+':/usr/local/bin:/usr/bin:/bin')
        execute(['bash','--noprofile','--rcfile',home/'.bashrc','-ic',selection],shell_env)
        execute(['bash','--noprofile','--norc','-ic','. '+shlex.quote(str(login))+'\n'+selection],shell_env)
        if snapshot(root,home)!=before:raise m.InstallError('Environment/cache/registry verification differs; activation settings will be rolled back.')
        result.update(status='PASS',version=config['MicromambaVersion'],other_environments='PRESERVED',activation_specs_checked=checked,activation_hooks_executed_in_other_environments=False,normal_bash_selection='PASS',login_profile_selection='PASS',restart_required=True,instruction='Open a new terminal, or run: . '+shlex.quote(str(hook))+' ; hash -r\nThen restart the installer. The running parent shell cannot be changed by this installer.')
    except BaseException as error:
        for path in reversed(changed):
            saved=preserved[str(path)]
            if saved:m.atomic_bytes(path,Path(saved['backup']).read_bytes(),saved['mode'])
            elif path.exists():path.unlink()
        result.update(reason=str(error),rolled_back=True,other_environments='PRESERVED' if snapshot(root,home)==before else 'FAIL',instruction='The previous executable selection and per-user settings were restored. Resolve the reported check before retrying; do not use sudo.')
        if isinstance(error,(KeyboardInterrupt,SystemExit)):raise
    (backup/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result
