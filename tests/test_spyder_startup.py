"""Isolated startup/import regressions; never launch or modify a real environment."""
import json
import importlib.util
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
import importlib.util, json, os, pathlib, sys, types
support=pathlib.Path(sys.argv[1]);mode=sys.argv[2];work=pathlib.Path(sys.argv[3])
prefix=work/'root/envs/science'
def load(name, filename):
    spec=importlib.util.spec_from_file_location(name,support/filename)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
original_path=list(sys.path)
# A kernel can already contain same-named modules from another checkout.
foreign=types.ModuleType('science_integrity');foreign.__file__='/foreign/science_integrity.py'
foreign.verify=lambda *a: (_ for _ in ()).throw(AssertionError('Foreign integrity used'))
if sys.argv[4]=='foreign':sys.modules['science_integrity']=foreign
foreign_config=types.ModuleType('science_config')
if sys.argv[4]=='foreign':sys.modules['science_config']=foreign_config
if mode=='manager':
    manager=load('manager_from_external_cwd','science-manager.py')
    assert pathlib.Path(manager.science_integrity.__file__)==support/'science_integrity.py'
    assert pathlib.Path(manager.science_config.__file__)==support/'science_config.py'
    assert manager.release()['Python']=='3.14'
    for obj in [manager.safety,manager.tx,manager.processes,manager.desktop_tools,manager.lifecycle]:
        assert pathlib.Path(obj.__file__).parent==support
elif mode=='runtime':
    runtime=load('runtime_from_kernel','science-runtime-check.py')
    manager=runtime.policy_manager()
    assert len(manager.release()['ScientificPackages'])==42
    startup=load('startup_from_kernel','science_startup.py')
    assert pathlib.Path(startup.module('fonts_from_kernel','science_fontconfig.py').__file__).parent==support
elif mode=='installer':
    installer=load('installer_from_external_cwd','science-install.py')
    assert pathlib.Path(installer.m.science_integrity.__file__).parent==support
    assert pathlib.Path(installer.science_integrity.__file__).parent==support
elif mode in ['frontend','launch','tamper']:
    entry=load('managed_startup','science-spyder-start.py')
    calls={}
    class Conf:
        def set(self,section,key,value):calls[(section,key)]=value
    for name in ['spyder','spyder.config','spyder.config.manager']:
        sys.modules[name]=types.ModuleType(name)
    sys.modules['spyder.config.manager'].CONF=Conf()
    if mode=='tamper':
        try:entry.configure_frontend(prefix,work/'profile')
        except SystemExit as error:assert 'SHA256 mismatch' in str(error)
        else:raise AssertionError('Tampered bundle loaded')
        assert not calls
    else:
        if mode=='frontend':entry.configure_frontend(prefix,work/'profile')
        else:
            (prefix/'bin').mkdir(parents=True);(prefix/'bin/spyder').touch()
            real_loader=entry.load_support_module
            def loader(name,filename):
                value=real_loader(name,filename)
                if filename=='science-runtime-check.py':
                    value.identity=lambda selected: {'python_in_science':selected==prefix}
                return value
            entry.load_support_module=loader
            def execv(executable,argv):
                assert executable==str(prefix/'bin/spyder')
                assert argv==[str(prefix/'bin/spyder'),'--new-instance','--help']
                calls['exec']=True
            entry.launch(['--help'],prefix=prefix,execv=execv)
            assert calls['exec']
        assert calls[('main_interpreter','default')] is True
        assert calls[('main_interpreter','custom')] is False
        assert calls[('main_interpreter','executable')]==str(prefix/'bin/python')
        assert pathlib.Path(os.environ['SPYDER_CONFDIR']).is_relative_to(work)
assert sys.path==original_path, 'Startup changed the global import search path'
if sys.argv[4]=='foreign':
    assert sys.modules['science_integrity'] is foreign
    assert sys.modules['science_config'] is foreign_config
else:
    assert 'science_integrity' not in sys.modules
    assert 'science_config' not in sys.modules
print(json.dumps({'mode':mode,'cwd':str(pathlib.Path.cwd()),'import_path_unchanged':True}))
'''


class SpyderStartupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='science-startup-tests-', dir='/tmp')
        self.work = Path(self.temporary.name)
        self.support = self.work/'installed-root/share/scientific-python'
        shutil.copytree(ROOT/'linux', self.support)
        shutil.copytree(ROOT/'shared', self.support/'shared')
        self.outside = self.work/'unrelated-working-directory'
        self.outside.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def probe(self, mode, support=None, cwd=None, cache="clean"):
        case=self.work/('case-'+mode);case.mkdir(exist_ok=True)
        env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1', HOME=str(case/'private-home'),
                 XDG_CONFIG_HOME=str(case/'config'), XDG_CACHE_HOME=str(case/'cache'),
                 XDG_DATA_HOME=str(case/'data'), LOCALAPPDATA=str(case/'local'))
        env.pop('PYTHONPATH', None);env.pop('PYTHONHOME', None)
        result=subprocess.run([sys.executable,'-B','-c',PROBE,str(support or self.support),mode,str(case),cache],
                              cwd=cwd or self.outside,env=env,capture_output=True,text=True,timeout=25)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        return json.loads(result.stdout)

    def test_manager_from_source_and_installed_support_outside_directory(self):
        for support in [ROOT/'linux',self.support]:
            for cwd in [self.outside,Path.home()]:
                with self.subTest(support=support,cwd=cwd):self.probe('manager',support,cwd)

    def test_managed_frontend_from_home_and_unrelated_directory(self):
        for cwd in [self.outside,Path.home()]:
            with self.subTest(cwd=cwd):self.probe('frontend',cwd=cwd)

    def test_deferred_runtime_and_startup_dependencies_from_home(self):
        self.probe('runtime',cwd=Path.home())

    def test_dynamically_loaded_installer_from_home(self):
        self.probe('installer',cwd=Path.home())

    def test_frontend_launch_and_interpreter_configuration_target_science(self):
        self.probe('launch',cwd=Path.home())

    def test_foreign_cached_modules_do_not_override_bundle(self):
        for mode in ['manager','frontend','runtime']:
            with self.subTest(mode=mode):self.probe(mode,cwd=Path.home(),cache='foreign')

    def test_integrity_failure_does_not_change_import_path_or_settings(self):
        path=self.support/'science_safety.py';path.write_bytes(path.read_bytes()+b'\n# tamper fixture\n')
        self.probe('tamper',cwd=Path.home())

    def activation_fixture(self):
        root=self.support.parent.parent;prefix=root/'envs/science'
        (prefix/'conda-meta').mkdir(parents=True);(prefix/'conda-meta/history').touch()
        (prefix/'.science-owner.json').write_text(json.dumps({'managed_by':'scientific-python-ubuntu','root':str(root)}))
        spec=importlib.util.spec_from_file_location('activation_test_manager',self.support/'science-manager.py')
        manager=importlib.util.module_from_spec(spec);spec.loader.exec_module(manager)
        for active,folder in [(True,'activate.d'),(False,'deactivate.d')]:
            path=prefix/'etc/conda'/folder/'scientific-python-spyder.sh'
            path.parent.mkdir(parents=True)
            path.write_text(manager.spyder_profile_hook(root,self.support,active))
        private_home=self.work/'activation-home';private_home.mkdir()
        key=hashlib.sha256(str(root).encode()).hexdigest()[:16]
        profile=private_home/'.config/scientific-python'/('spyder-'+key)
        return root,prefix,private_home,profile

    def test_activation_manager_cli_in_isolated_python_from_home_and_outside(self):
        root,prefix,private_home,profile=self.activation_fixture()
        env=dict(os.environ,HOME=str(private_home),PYTHONPATH='/must-not-be-needed',SPYDER_CONFDIR='/previous-profile')
        for cwd in [Path.home(),self.outside]:
            with self.subTest(cwd=cwd):
                result=subprocess.run(['/usr/bin/python3','-I','-B',str(self.support/'science-manager.py'),'spyder-profile','--root',str(root)],cwd=cwd,env=env,capture_output=True,text=True,timeout=15)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout.strip(),str(profile))
        self.assertIn('default = True',(profile/'config/spyder.ini').read_text())
        self.assertIn('custom = False',(profile/'config/spyder.ini').read_text())
        self.assertIn(str(prefix/'bin/python'),(profile/'config/transient.ini').read_text())

    @unittest.skipUnless(os.environ.get('SCIENCE_TEST_MICROMAMBA') or shutil.which('micromamba') or (Path.home()/'.local/bin/micromamba').is_file(),'Micromamba runtime not available')
    def test_real_micromamba_activation_and_deactivation_in_temporary_root(self):
        import shlex
        root,prefix,private_home,profile=self.activation_fixture()
        binary=os.environ.get('SCIENCE_TEST_MICROMAMBA') or shutil.which('micromamba') or str(Path.home()/'.local/bin/micromamba')
        shell=textwrap.dedent("""\
            set -euo pipefail
            export MAMBA_EXE=@MM@
            export MAMBA_ROOT_PREFIX=@ROOT@
            eval "$($MAMBA_EXE shell hook --shell bash --root-prefix "$MAMBA_ROOT_PREFIX")"
            export SPYDER_CONFDIR=/previous-profile
            micromamba activate science
            [[ "$CONDA_PREFIX" == @PREFIX@ && "$SPYDER_CONFDIR" == @PROFILE@ ]]
            micromamba deactivate
            [[ "$SPYDER_CONFDIR" == /previous-profile ]]
            printf 'ACTIVATION_OK\\n'
        """)
        shell=shell.replace('@MM@',shlex.quote(str(binary))).replace('@ROOT@',shlex.quote(str(root))).replace('@PREFIX@',shlex.quote(str(prefix))).replace('@PROFILE@',shlex.quote(str(profile)))
        env={k:v for k,v in os.environ.items() if not k.startswith(('CONDA_','MAMBA_','PYTHON'))}
        env.update(HOME=str(private_home),PYTHONDONTWRITEBYTECODE='1',XDG_CACHE_HOME=str(self.work/'activation-cache'),XDG_CONFIG_HOME=str(private_home/'.config'))
        for cwd in [Path.home(),self.outside]:
            with self.subTest(cwd=cwd):
                result=subprocess.run(['bash','--noprofile','--norc','-c',shell],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('ACTIVATION_OK',result.stdout)

    def test_shell_launcher_selects_science_over_foreign_active_environment(self):
        root=self.work/'selected-root';science=root/'envs/science';(science/'bin').mkdir(parents=True)
        (science/'bin/python').touch();(science/'bin/python').chmod(0o755)
        executable=self.work/'micromamba-stub'
        executable.write_text('#!'+sys.executable+'\n'+textwrap.dedent('''\
            import json,os,sys
            print(json.dumps({'args':sys.argv[1:],'env':{key:os.environ.get(key) for key in ['MAMBA_ROOT_PREFIX','MAMBA_EXE','CONDA_EXE','PYTHONPATH','PYTHONHOME']}}))
        '''));executable.chmod(0o755)
        import shlex
        template=(ROOT/'linux/spyder-launcher.sh').read_text()
        launcher=self.work/'science-spyder'
        launcher.write_text(template.replace('@ROOT@',shlex.quote(str(root))).replace('@MM@',shlex.quote(str(executable))).replace('@ROOT_ID@','fixture'))
        foreign=self.work/'envs/py314-opencv5-cuda'
        env=dict(os.environ,CONDA_PREFIX=str(foreign),MAMBA_ROOT_PREFIX='/foreign-root',
                 MAMBA_EXE='/foreign-mamba',CONDA_EXE='/foreign-conda',PYTHONPATH='/foreign-modules',PYTHONHOME='/foreign-python')
        result=subprocess.run(['bash',str(launcher),'--version'],cwd=Path.home(),env=env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        value=json.loads(result.stdout)
        self.assertEqual(value['args'],['run','-r',str(root),'-p',str(science),str(science/'bin/python'),str(root/'share/scientific-python/science-spyder-start.py'),'--version'])
        self.assertEqual(value['env']['MAMBA_ROOT_PREFIX'],str(root))
        self.assertEqual(value['env']['MAMBA_EXE'],str(executable));self.assertEqual(value['env']['CONDA_EXE'],str(executable))
        self.assertIsNone(value['env']['PYTHONPATH']);self.assertIsNone(value['env']['PYTHONHOME'])

if __name__=='__main__':unittest.main(verbosity=2)
