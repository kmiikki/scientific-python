"""Opt-in config upgrade and coverage regressions; all writes use RAM fixtures."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
config=load('upgrade_configuration',ROOT/'linux/science_config.py')
report=load('shared_package_report',ROOT/'shared/science_package_report.py')
CASES=json.loads((ROOT/'shared/fixtures/release-upgrade-cases.json').read_text())

class ReleaseUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='science-release-upgrade-',dir='/tmp')
        self.work=Path(self.temp.name);self.path=self.work/'science-release.json'
    def tearDown(self):self.temp.cleanup()
    def save(self,value):
        self.path.write_bytes(('\ufeff'+json.dumps(value,separators=(',',':'))+'\n').encode())
    def value(self,case):
        value=config.defaults(ROOT/'linux')
        value['ScientificPackages']=[case.get('replace',{}).get(config.spec_name(s),s) for s in value['ScientificPackages'] if config.spec_name(s) not in case['remove']]+case.get('append',[])
        if 'channels' in case:value['Channels']=case['channels']
        return value
    def test_shared_approval_decline_identity_and_idempotence_cases(self):
        for case in CASES:
            with self.subTest(case=case['id']):
                value=self.value(case);self.save(value);self.path.chmod(0o640)
                before=self.path.read_bytes();stamp=self.path.stat().st_mtime_ns;calls=[];output=[]
                def review(prompt):calls.append(prompt);return case['answer']
                self.assertEqual([config.spec_name(s) for s in config.missing_release_packages(value,ROOT/'linux')],case['missing'])
                result=config.offer_release_packages(ROOT/'linux',self.path,case['interactive'],review,output.append)
                self.assertEqual(result['Channels'],value['Channels'])
                self.assertEqual(result['ScientificPackages'],value['ScientificPackages']+case['added'])
                self.assertEqual(bool(calls),bool(case['missing']) and case['interactive'])
                self.assertEqual(stat.S_IMODE(self.path.stat().st_mode),0o640)
                if not case['added']:
                    self.assertEqual(self.path.read_bytes(),before);self.assertEqual(self.path.stat().st_mtime_ns,stamp)
                else:
                    stamp=self.path.stat().st_mtime_ns;before=self.path.read_bytes()
                    config.offer_release_packages(ROOT/'linux',self.path,True,lambda _:self.fail('No second prompt expected'),lambda _:None)
                    self.assertEqual(self.path.read_bytes(),before);self.assertEqual(self.path.stat().st_mtime_ns,stamp)
                self.assertEqual(list(self.work.glob('.science-config-*')),[])
                self.assertEqual(list(self.work.glob('*.legacy-*')),[])
    def test_fresh_initialization_already_contains_42_and_needs_no_review(self):
        config.initialize(ROOT/'linux',path=self.path)
        value=config.offer_release_packages(ROOT/'linux',self.path,True,lambda _:self.fail('Unexpected prompt'),lambda _:None)
        self.assertEqual(len(value['ScientificPackages']),42)
    def test_invalid_config_fails_without_writing_or_prompting(self):
        for text in ['{bad}',json.dumps({'SchemaVersion':1,'Channels':['conda-forge'],'ScientificPackages':['numpy','numpy>=2']})]:
            self.path.write_text(text);before=self.path.read_bytes()
            with self.assertRaises(config.ConfigError):config.offer_release_packages(ROOT/'linux',self.path,True,lambda _:self.fail('Invalid config prompted'))
            self.assertEqual(self.path.read_bytes(),before)
    def test_concurrent_edit_is_preserved_and_replacement_is_aborted(self):
        value=self.value(CASES[1]);self.save(value)
        changed=dict(value,Channels=['other-lab'])
        def review(_):self.path.write_text(json.dumps(changed));return 'yes'
        with self.assertRaisesRegex(config.ConfigError,'changed during review'):config.offer_release_packages(ROOT/'linux',self.path,True,review,lambda _:None)
        self.assertEqual(config.read_json(self.path),changed)
        self.assertEqual(list(self.work.glob('.science-config-*')),[])
    def test_failed_atomic_replace_preserves_original_and_cleans_staging(self):
        self.save(self.value(CASES[1]));before=self.path.read_bytes()
        with patch.object(config.os,'replace',side_effect=OSError('fixture replacement failure')):
            with self.assertRaises(OSError):config.offer_release_packages(ROOT/'linux',self.path,True,lambda _:'yes',lambda _:None)
        self.assertEqual(self.path.read_bytes(),before);self.assertEqual(list(self.work.glob('.science-config-*')),[])
    def test_resulting_configuration_is_validated_before_replacement(self):
        value=self.value(CASES[1]);self.save(value);before=self.path.read_bytes()
        new_defaults={'SchemaVersion':1,'Channels':['new-channel'],'ScientificPackages':['new-channel::shap']}
        with patch.object(config,'defaults',return_value=new_defaults):
            with self.assertRaises(config.ConfigError):config.offer_release_packages(ROOT/'linux',self.path,True,lambda _:'yes',lambda _:None)
        self.assertEqual(self.path.read_bytes(),before)
    def test_coverage_distinguishes_decline_missing_and_failed_import(self):
        defaults=config.defaults(ROOT/'linux');effective=self.value(CASES[1])
        records=[{'name':config.spec_name(s)} for s in effective['ScientificPackages']]
        status=report.coverage(effective,defaults,records)
        self.assertEqual(status['status'],'PASS');self.assertEqual(status['release_default_coverage'],'INCOMPLETE')
        self.assertEqual(set(status['release_not_requested']),set(CASES[1]['missing']))
        self.assertEqual(status['missing_effective'],[])
        records=[r for r in records if r['name']!='numpy']
        self.assertEqual(report.coverage(effective,defaults,records)['missing_effective'],['numpy'])
        checks=[{'package':'shap','module':'shap','status':'FAIL'}]
        full=[{'name':config.spec_name(s)} for s in defaults['ScientificPackages']]
        self.assertEqual(report.coverage(defaults,defaults,full,checks)['status'],'FAIL')
        self.assertNotIn('shap',report.coverage(defaults,defaults,full,checks)['verified_imports'])
        self.assertEqual(report.RELEASE_IMPORTS,{'shap':'shap','pywavelets':'pywt','optuna':'optuna','plotly':'plotly','hypothesis':'hypothesis','polars':'polars','xgboost':'xgboost'})
    def test_linux_failed_package_stage_includes_effective_and_release_coverage(self):
        value=self.value(CASES[1]);active=self.work/'config/scientific-python/science-release.json';active.parent.mkdir(parents=True);active.write_text(json.dumps(value))
        prefix=self.work/'root/envs/science';metadata=prefix/'conda-meta';metadata.mkdir(parents=True)
        rows=json.loads((ROOT/'shared/fixtures/approved-linux-records.json').read_text())
        for row in rows:
            if row['name'] not in CASES[1]['remove']+['numpy']:(metadata/(row['name']+'.json')).write_text(json.dumps(row))
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',XDG_CONFIG_HOME=str(self.work/'config'))
        p=subprocess.run([sys.executable,'-B',str(ROOT/'linux/science-runtime-check.py'),'--prefix',str(prefix),'--stage','packages'],cwd=self.work,env=env,capture_output=True,text=True,timeout=15)
        self.assertNotEqual(p.returncode,0)
        result=json.loads(p.stdout.split('SCIENCE_RESULT=')[-1]);coverage=result['details']['package_selection']
        self.assertEqual(coverage['missing_effective'],['numpy']);self.assertEqual(set(coverage['release_not_requested']),set(CASES[1]['remove']))
    def test_windows_runtime_selects_imports_by_effective_identity(self):
        value=self.value(CASES[1]);active=self.work/'local/ScientificPython/science-release.json';active.parent.mkdir(parents=True);active.write_text(json.dumps(value))
        with patch.dict(os.environ,{'LOCALAPPDATA':str(self.work/'local')}):
            runtime=load('windows_upgrade_runtime',ROOT/'windows/science-runtime-check.py')
            self.assertNotIn('pywt',runtime.IMPORTS);self.assertNotIn('shap',runtime.IMPORTS);self.assertIn('shapely',runtime.IMPORTS)
            prefix=self.work/'windows-root/envs/science';meta=prefix/'conda-meta';meta.mkdir(parents=True)
            for spec in value['ScientificPackages']:
                name=config.spec_name(spec);(meta/(name+'.json')).write_text(json.dumps({'name':name}))
            selection=runtime.package_selection(prefix)
            self.assertEqual(selection['status'],'PASS');self.assertEqual(selection['release_default_coverage'],'INCOMPLETE')
            self.assertEqual(set(selection['release_not_requested']),set(CASES[1]['missing']))
            (meta/'numpy.json').unlink()
            self.assertEqual(runtime.package_selection(prefix)['missing_effective'],['numpy'])
            value['ScientificPackages']+=['pywavelets>=1','shap'];active.write_text(json.dumps(value))
            runtime=load('windows_upgrade_runtime_included',ROOT/'windows/science-runtime-check.py')
            self.assertIn('pywt',runtime.IMPORTS);self.assertIn('shap',runtime.IMPORTS)
    def test_approved_requests_reach_native_preflight_and_preserve_other_environment(self):
        self.save(self.value(CASES[1]));config.offer_release_packages(ROOT/'linux',self.path,True,lambda _:'yes',lambda _:None)
        manager=load('upgrade_native_manager',ROOT/'linux/science-manager.py')
        effective=dict(config.read_json(ROOT/'linux/science-installer-release.json'),**config.read_json(self.path))
        root=self.work/'native-root';other=root/'envs/py314-opencv5-cuda/KEEP';other.parent.mkdir(parents=True);other.write_text('unchanged')
        captured=[]
        class Captured(Exception):pass
        def runner(argv,**kwargs):captured.extend(argv);raise Captured()
        with contextlib.ExitStack() as stack:
            for name,value in [('guard_root',root),('guard_science',None),('read_state',{'managed_by':'test'}),('using_science',False),('locked',contextlib.nullcontext())]:
                stack.enter_context(patch.object(manager,name,return_value=value))
            with self.assertRaises(Captured):manager.sync(root,effective,runner=runner,mm=self.work/'unused-mm')
        for name in CASES[1]['missing']:self.assertIn(name,captured)
        self.assertIn('--dry-run',captured);self.assertEqual(other.read_text(),'unchanged')
        def unsatisfiable(argv,**kwargs):return subprocess.CompletedProcess(argv,1,json.dumps({'success':False,'solver_problems':['fixture incompatibility']}),'fixture incompatibility')
        before=self.path.read_bytes()
        with contextlib.ExitStack() as stack:
            for name,value in [('guard_root',root),('guard_science',None),('read_state',{'managed_by':'test'}),('using_science',False),('locked',contextlib.nullcontext())]:
                stack.enter_context(patch.object(manager,name,return_value=value))
            with self.assertRaises(manager.InstallError):manager.sync(root,effective,runner=unsatisfiable,mm=self.work/'unused-mm')
        self.assertEqual(self.path.read_bytes(),before);self.assertEqual(other.read_text(),'unchanged')

if __name__=='__main__':unittest.main(verbosity=2)
