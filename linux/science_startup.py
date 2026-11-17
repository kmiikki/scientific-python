"""Bounded, event-driven real Spyder main-window startup and recovery."""
import importlib.util
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import time
import uuid

BUNDLE=Path(__file__).resolve().parent


def module(name,file):
    spec=importlib.util.spec_from_file_location(name,BUNDLE/file);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


def plain(path):
    for part in [Path(path),*Path(path).parents]:
        if part.is_symlink():raise RuntimeError('Symlinked startup-test/report path refused: '+str(part))


def graphical_session(env):
    # Offscreen/minimal Qt and a bare Xvfb display do not certify a real desktop.
    return bool((env.get('DISPLAY') or env.get('WAYLAND_DISPLAY')) and env.get('XDG_SESSION_TYPE') in ['x11','wayland'] and env.get('QT_QPA_PLATFORM','') not in ['offscreen','minimal'])


def group_members(pgid):
    result=[]
    for entry in Path('/proc').glob('[0-9]*'):
        try:
            text=(entry/'stat').read_text();tail=text[text.rfind(')')+2:].split()
            if int(tail[2])==pgid and tail[0]!='Z':result.append(int(entry.name))
        except (OSError,ValueError,IndexError):continue
    return result


def token_members(token):
    result=[]
    for process in Path('/proc').glob('[0-9]*'):
        try:
            if process.stat().st_uid!=os.getuid():continue
            if ('SCIENCE_STARTUP_TOKEN='+token).encode() in (process/'environ').read_bytes().split(b'\0'):
                text=(process/'stat').read_text();tail=text[text.rfind(')')+2:].split()
                if tail[0]!='Z':result.append(int(process.name))
        except (OSError,ValueError):continue
    return result


def stop_owned(process,token):
    # Never kill unrelated user applications and never escalate to SIGKILL.
    tokens=token_members(token);group=group_members(process.pid)
    owned_group=process.returncode is None or bool(set(tokens)&set(group))
    remaining=sorted(set(tokens+(group if owned_group else [])))
    if remaining and owned_group:
        try:os.killpg(process.pid,signal.SIGTERM)
        except ProcessLookupError:pass
    for pid in token_members(token):
        try:os.kill(pid,signal.SIGTERM)
        except ProcessLookupError:pass
    try:process.wait(timeout=15)
    except subprocess.TimeoutExpired:pass
    deadline=time.monotonic()+5
    while ((group_members(process.pid) if owned_group else []) or token_members(token)) and time.monotonic()<deadline:time.sleep(.1)
    return sorted(set((group_members(process.pid) if owned_group else [])+token_members(token)))


def check_events(path,token,stable_seconds):
    events=[]
    if path.is_file():
        for line in path.read_text(errors='replace').splitlines():
            try:
                event=json.loads(line)
                if event.get('token')==token:events.append(event)
            except ValueError:continue
    ready=next((e for e in events if e.get('event')=='mainwindow_ready'),None)
    stable=next((e for e in events if e.get('event')=='stable'),None)
    closed=any(e.get('event')=='closing' for e in events) and not any(e.get('event') in ['close_refused','window_disappeared','window_not_ready'] for e in events)
    passed=bool(ready and stable and closed and stable.get('elapsed',0)>=stable_seconds and stable.get('heartbeats',0)>=3 and ready.get('visible') is True)
    return passed,events


def attempt(prefix,launcher,directory,timeout=120,stable_seconds=5,popen=subprocess.Popen,env=None,debug=False):
    env=os.environ.copy() if env is None else dict(env);directory=Path(directory);directory.mkdir(parents=True,exist_ok=False)
    token=uuid.uuid4().hex;profile=directory/'profile';profile.mkdir();(profile/'.science-test-profile').write_text(token)
    events=directory/'events.jsonl';control=directory/'control.json'
    control.write_text(json.dumps({'token':token,'profile':str(profile),'events':str(events),'stable_seconds':stable_seconds}))
    os.chmod(control,0o600)
    env.update(PYTHONFAULTHANDLER='1',QT_LOGGING_RULES='qt.qpa.*=true',SCIENCE_STARTUP_TOKEN=token)
    # The test's kernel/project/runtime files stay private; the actual selected
    # font cache is retained so the test can expose the user's fontconfig defect.
    env.update(IPYTHONDIR=str(directory/'ipython'),JUPYTER_CONFIG_DIR=str(directory/'jupyter'),JUPYTER_RUNTIME_DIR=str(directory/'runtime'),MPLCONFIGDIR=str(directory/'matplotlib'))
    command=[str(launcher),'--science-startup-probe',str(control),'--new-instance','--debug-info','verbose','--debug-output','terminal']
    if debug:
        command=['gdb','--batch','--return-child-result','-ex','set pagination off','-ex','run','-ex','thread apply all bt','--args',str(prefix/'bin/python'),str(BUNDLE/'science-spyder-start.py'),*command[1:]]
    output=directory/'stdout.log';error=directory/'stderr.log';started=time.monotonic();timed_out=False
    with output.open('w') as stdout,error.open('w') as stderr:
        process=popen(command,env=env,cwd=directory,stdout=stdout,stderr=stderr,start_new_session=True)
        try:
            try:process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:timed_out=True
        finally:
            remaining=stop_owned(process,token)
    passed,observed=check_events(events,token,stable_seconds)
    text=error.read_text(errors='replace');out=output.read_text(errors='replace');code=process.returncode
    segfault=code in [-signal.SIGSEGV,128+signal.SIGSEGV] or 'Segmentation fault' in text or 'Program received signal SIGSEGV' in out
    status='PASS' if passed and code==0 and not timed_out and not remaining else 'FAIL'
    reason='Spyder main window initialized, remained responsive and closed.' if status=='PASS' else ('Spyder main window did not finish before the timeout.' if timed_out else 'Spyder terminated abnormally or did not confirm a complete main window.')
    return {'status':status,'reason':reason,'exit_code':code,'segmentation_fault':segfault,'timed_out':timed_out,'duration':round(time.monotonic()-started,3),'main_window_event_seen':any(e['event']=='mainwindow_ready' for e in observed),'remaining_test_pids':remaining,'graceful_close':passed,'directory':str(directory),'stdout_file':str(output),'stderr_file':str(error),'stdout':out[-20000:],'stderr':text[-20000:]}


def run(prefix,launcher,home=None,env=None,runner=subprocess.run,attempt_fn=attempt):
    prefix=Path(prefix);root=prefix.parent.parent;home=Path.home() if home is None else Path(home);env=os.environ.copy() if env is None else dict(env)
    output=root/'science-spyder-startup.json'
    def save(value):
        plain(output);output.write_text(json.dumps(value,indent=2)+'\n');return value
    if not graphical_session(env):
        return save({'status':'PENDING','reason':'A real X11/Wayland desktop session is unavailable.','instruction':'Run menu V (Validation only) in your GNOME terminal. The next managed Spyder launch in a graphical session will run this bounded test automatically.','fontconfig_validation':{'status':'PENDING'},'remaining_test_pids':[]})
    directory=root/'.science-startup';plain(directory)
    owner=directory/'owner.json';expected={'managed_by':'scientific-python-ubuntu','root':str(root),'scope':'spyder-startup-tests'}
    if directory.exists():
        plain(owner)
        if not owner.is_file() or json.loads(owner.read_text())!=expected:raise RuntimeError('Unowned startup-test directory refused.')
    else:
        directory.mkdir();owner.write_text(json.dumps(expected)+'\n')
    import fcntl
    plain(directory/'test.lock')
    fd=os.open(directory/'test.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'a+b') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return {'status':'BLOCKED','reason':'Another managed Spyder startup test is running.'}
        attempt_root=directory/uuid.uuid4().hex;attempt_root.mkdir()
        first=attempt_fn(prefix,launcher,attempt_root/'initial',env=env)
        fonts=module('startup_fontconfig','science_fontconfig.py')
        diagnostic={}
        probe=runner([str(prefix/'bin/python'),str(BUNDLE/'science_fontconfig.py'),'--probe',str(prefix)],env=env,capture_output=True,text=True,timeout=30)
        try:
            if probe.returncode==0:diagnostic=json.loads(probe.stdout)
        except ValueError:pass
        first['fontconfig']=diagnostic;first['session']={k:env.get(k) for k in ['XDG_SESSION_TYPE','XDG_CURRENT_DESKTOP','DISPLAY','WAYLAND_DISPLAY']}
        final=first;repair_result={'status':'PASS' if first['status']=='PASS' else 'PENDING','reason':'Startup passed; no font cache rebuild was necessary.' if first['status']=='PASS' else 'No supported native fontconfig crash evidence yet.'}
        if first.get('segmentation_fault') and not fonts.supported_crash(first) and not first.get('remaining_test_pids') and __import__('shutil').which('gdb'):
            debug=attempt_fn(prefix,launcher,attempt_root/'native-diagnostic',env=env,debug=True)
            first['native_backtrace']=debug.get('stdout','')+debug.get('stderr','');first['native_diagnostic']=debug
        if first['status']!='PASS' and fonts.supported_crash(first) and diagnostic and not first.get('remaining_test_pids'):
            old_env=os.environ.copy()
            try:
                os.environ.update(env)
                repair_result=fonts.repair(prefix,home,diagnostic,root/'science-fontconfig-repair.json',runner=runner)
            finally:os.environ.clear();os.environ.update(old_env)
            if repair_result['status']=='REBUILT':
                final=attempt_fn(prefix,launcher,attempt_root/'after-repair',env=env)
                repair_result['status']='PASS' if final['status']=='PASS' else 'FAIL'
                repair_result['retry_status']=final['status']
                state_path=root/'science-fontconfig-repair.json';state=json.loads(state_path.read_text());state['spyder_retry_status']=final['status'];state['status']=repair_result['status'];state_path.write_text(json.dumps(state,indent=2)+'\n')
        result={key:value for key,value in final.items() if key not in ['stdout','stderr']}
        result.update(initial_attempt=first,fontconfig_validation=repair_result,fontconfig=diagnostic,user_gui_acceptance='PENDING')
        if result['status']!='PASS':result['instruction']='Read '+str(output)+'. Close only remaining test processes listed there if any, resolve the reported crash/timeout, then run menu V. Cache backups are never deleted automatically.'
        return save(result)


def instrument(control_path):
    """Run inside the real Spyder entrypoint, before MainWindow construction."""
    control_path=Path(control_path)
    if control_path.is_symlink() or control_path.stat().st_uid!=os.getuid():raise RuntimeError('Unsafe startup control file')
    config=json.loads(control_path.read_text());profile=Path(config['profile']);events=Path(config['events'])
    if profile.parent!=control_path.parent or events.parent!=control_path.parent or profile.is_symlink() or events.is_symlink() or (profile/'.science-test-profile').read_text()!=config['token']:raise RuntimeError('Startup test paths do not match the private test profile.')
    os.environ['SPYDER_CONFDIR']=str(profile)
    from spyder.config.manager import CONF
    for key,value in [('single_instance',False),('prompt_on_exit',False),('check_updates_on_startup',False),('show_internal_errors',False)]:CONF.set('main',key,value)
    from qtpy.QtCore import QTimer
    from qtpy.QtWidgets import QApplication
    from spyder.app.mainwindow import MainWindow
    original=MainWindow.__init__
    def emit(event,**values):
        with events.open('a') as stream:stream.write(json.dumps(dict(values,event=event,token=config['token'],pid=os.getpid()))+'\n');stream.flush()
    def initialize(window,*args,**kwargs):
        original(window,*args,**kwargs)
        def ready():
            def start_heartbeat():
                if not window.isVisible() or window.is_setting_up:emit('window_not_ready');return
                emit('mainwindow_ready',visible=True);started=time.monotonic();beats=[0]
                timer=QTimer(window);window._science_startup_timer=timer
                def beat():
                    beats[0]+=1
                    if not window.isVisible():emit('window_disappeared');timer.stop();QApplication.instance().quit();return
                    elapsed=time.monotonic()-started
                    emit('heartbeat',elapsed=elapsed)
                    if elapsed>=config['stable_seconds']:
                        timer.stop();emit('stable',elapsed=elapsed,heartbeats=beats[0]);emit('closing')
                        # closeEvent calls Spyder's normal plugin/kernel shutdown.
                        if window.close():QApplication.instance().quit()
                        else:emit('close_refused');QApplication.instance().quit()
                timer.timeout.connect(beat);timer.start(250)
            QTimer.singleShot(0,start_heartbeat)
        window.sig_setup_finished.connect(ready)
    MainWindow.__init__=initialize
    return profile
