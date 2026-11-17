import ast
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'linux'))
import science_config as config
import science_integrity as integrity
FIXTURES=ROOT/'shared/fixtures'

class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.context=tempfile.TemporaryDirectory(prefix='science-config-test-',dir='/tmp')
        self.work=Path(self.context.name)
    def tearDown(self):self.context.cleanup()
    def test_shared_configuration_contract(self):
        for case in config.read_json(FIXTURES/'configuration-cases.json'):
            with self.subTest(case=case['id']):
                value=config.defaults(ROOT/'linux')
                value.update(case.get('changes',{}))
                if 'append' in case:value['ScientificPackages'].append(case['append'])
                if 'remove' in case:value['ScientificPackages'].remove(case['remove'])
                data=bytes.fromhex(case['hex']) if 'hex' in case else case.get('raw',json.dumps(value)).encode()
                if case.get('bom'):data=b'\xef\xbb\xbf'+data
                path=self.work/'input.json';path.write_bytes(data)
                if case['valid']:config.validate(config.read_json(path),ROOT/'linux')
                else:
                    with self.assertRaises(config.ConfigError):config.validate(config.read_json(path),ROOT/'linux')
    def test_42_approved_defaults_and_no_optional_packages(self):
        value=config.defaults(ROOT/'linux');names={config.spec_name(x) for x in value['ScientificPackages']}
        self.assertEqual(len(names),42)
        self.assertTrue({'shap','pywavelets','optuna','plotly','hypothesis','polars','xgboost'}<=names)
        self.assertFalse({'pytorch','torchvision','lightgbm','pingouin','simplecv'}&names)
        legacy=set(config.read_json(FIXTURES/'linux-legacy.json')['ScientificPackages'])
        self.assertEqual(names, legacy | {'python','python_abi','spyder','apache-arrow-proc','opencv','ffmpeg','shap','pywavelets','optuna','plotly','hypothesis','polars','xgboost'})
    def test_linux_migration_preserves_preferences_and_backup(self):
        legacy=config.read_json(FIXTURES/'linux-legacy.json')
        legacy['ScientificPackages'].remove('seaborn');legacy['ScientificPackages'].remove('numpy')
        legacy['ScientificPackages']+=['numpy>=2,<3',"pytorch[build='cpu*']",'my-lab::custom-package=1']
        legacy['Channels']=['conda-forge','my-lab']
        source=self.work/'legacy.json';original=json.dumps(legacy).encode();source.write_bytes(original)
        active=self.work/'config/science-release.json'
        value=config.initialize(ROOT/'linux',path=active,legacy=source)
        self.assertEqual(value['ScientificPackages'][6:],legacy['ScientificPackages'])
        self.assertEqual(value['Channels'],legacy['Channels'])
        self.assertEqual(source.read_bytes(),original)
        self.assertEqual(next(active.parent.glob('science-release.legacy-*.json')).read_bytes(),original)
        before=active.read_bytes();mtime=active.stat().st_mtime_ns
        config.initialize(ROOT/'linux',path=active,legacy=source)
        self.assertEqual(active.read_bytes(),before);self.assertEqual(active.stat().st_mtime_ns,mtime)
        source.unlink()
        config.initialize(ROOT/'linux',path=active,legacy=source)
        self.assertEqual(active.read_bytes(),before);self.assertEqual(active.stat().st_mtime_ns,mtime)
        self.assertNotIn('polars',{config.spec_name(s) for s in value['ScientificPackages']})
    def test_missing_configuration_with_existing_environment_is_not_clean(self):
        root=self.work/'root';(root/'envs/science').mkdir(parents=True)
        sentinel=root/'envs/science/KEEP';sentinel.write_bytes(b'unchanged')
        active=self.work/'config/science-release.json'
        with self.assertRaisesRegex(config.ConfigError,'Existing Science'):
            config.initialize(ROOT/'linux',root=root,path=active)
        self.assertFalse(active.exists());self.assertEqual(sentinel.read_bytes(),b'unchanged')
    def test_another_targets_default_does_not_authorize_unknown_existing_environment(self):
        active=self.work/'config/science-release.json'
        config.initialize(ROOT/'linux',root=self.work/'new-root',path=active)
        original=active.read_bytes()
        unknown=self.work/'unknown-root';(unknown/'envs/science').mkdir(parents=True)
        marker=unknown/'envs/science/KEEP';marker.write_text('keep')
        with self.assertRaisesRegex(config.ConfigError,'matching original configuration'):
            config.initialize(ROOT/'linux',root=unknown,path=active)
        self.assertEqual(active.read_bytes(),original);self.assertEqual(marker.read_text(),'keep')
    def test_clean_initialization(self):
        active=self.work/'config/science-release.json'
        self.assertEqual(len(config.initialize(ROOT/'linux',root=self.work/'new-root',path=active)['ScientificPackages']),42)
    def test_unknown_legacy_format_never_overwrites(self):
        source=self.work/'old.json';data=b'{"Python":"3.14"}';source.write_bytes(data)
        active=self.work/'config/science-release.json'
        with self.assertRaises(config.ConfigError):config.initialize(ROOT/'linux',path=active,legacy=source)
        self.assertEqual(source.read_bytes(),data);self.assertFalse(active.exists())
    def test_user_edits_survive_source_update_and_do_not_touch_integrity(self):
        bundle=self.work/'bundle';shutil.copytree(ROOT/'linux',bundle/'linux');shutil.copytree(ROOT/'shared',bundle/'shared')
        active=self.work/'user/science-release.json';v=config.initialize(bundle/'linux',path=active)
        v['ScientificPackages']=[s for s in v['ScientificPackages'] if config.spec_name(s)!='seaborn']+['pingouin']
        active.write_text(json.dumps(v));before=active.read_bytes()
        # Simulate replacing immutable source/default files with a new distribution, not the user file.
        template=bundle/'shared/science-release.default.json'
        new_default=json.loads(template.read_text());new_default['ScientificPackages'].append('future-default-fixture')
        template.write_text(json.dumps(new_default))
        # A reviewed new distribution carries its corresponding immutable manifest.
        manifest=bundle/'linux/SHA256SUMS.txt'
        manifest.write_text('\n'.join((hashlib.sha256(template.read_bytes()).hexdigest()+'  shared/science-release.default.json') if line.endswith('  shared/science-release.default.json') else line for line in manifest.read_text().splitlines())+'\n')
        self.assertTrue(integrity.verify(bundle/'linux'))
        config.initialize(bundle/'linux',path=active)
        self.assertEqual(active.read_bytes(),before)
    def test_immutable_script_and_schema_tamper(self):
        bundle=self.work/'bundle';shutil.copytree(ROOT/'linux',bundle/'linux');shutil.copytree(ROOT/'shared',bundle/'shared')
        for name in ['linux/science-manager.py','shared/science-release.schema.json','linux/science-installer-release.json']:
            path=bundle/name;before=path.read_bytes();path.write_bytes(before+b' ')
            with self.assertRaisesRegex(ValueError,'SHA256 mismatch'):integrity.verify(bundle/'linux')
            path.write_bytes(before)
        self.assertTrue(integrity.verify(bundle/'linux'))
    def test_symlink_config_is_rejected(self):
        target=self.work/'real.json';target.write_text(json.dumps(config.defaults(ROOT/'linux')))
        link=self.work/'link.json';link.symlink_to(target)
        with self.assertRaises(config.ConfigError):config.initialize(ROOT/'linux',path=link)
    def test_manager_uses_list_channels_and_existing_no_removal_guard(self):
        spec=importlib.util.spec_from_file_location('phase_manager',ROOT/'linux/science-manager.py');manager=importlib.util.module_from_spec(spec);spec.loader.exec_module(manager)
        user=config.defaults(ROOT/'linux');policy=config.read_json(ROOT/'linux/science-installer-release.json');effective=dict(policy,**user)
        self.assertEqual(manager.specs(effective),user['ScientificPackages'])
        plan={'success':True,'actions':{'LINK':config.read_json(FIXTURES/'approved-linux-records.json')}}
        before={'user-independent':{'name':'user-independent','version':'1','build':'0'}}
        plan['actions']['UNLINK']=[before['user-independent']]
        with self.assertRaisesRegex(manager.InstallError,'Refusing removal'):manager.check_plan(plan,before,effective,{'user-independent'})
    def test_linux_preflight_uses_only_configured_channels_and_variant_neutral_request(self):
        spec=importlib.util.spec_from_file_location('preflight_manager',ROOT/'linux/science-manager.py');manager=importlib.util.module_from_spec(spec);spec.loader.exec_module(manager)
        effective=dict(config.read_json(ROOT/'linux/science-installer-release.json'),**config.defaults(ROOT/'linux'))
        effective['Channels']=['conda-forge','my-lab'];effective['ScientificPackages'].append('pytorch')
        root=self.work/'isolated-root';root.mkdir();captured={}
        class PreflightCaptured(Exception):pass
        def runner(argv,env=None,**kwargs):
            captured.update(argv=argv,env=env);raise PreflightCaptured()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(manager,'guard_root',return_value=root))
            stack.enter_context(patch.object(manager,'guard_science'))
            stack.enter_context(patch.object(manager,'read_state',return_value={'managed_by':'test'}))
            stack.enter_context(patch.object(manager,'using_science',return_value=False))
            stack.enter_context(patch.object(manager,'locked',return_value=contextlib.nullcontext()))
            stack.enter_context(patch.dict(os.environ,{'MAMBA_CHANNELS':'defaults','CONDA_CHANNELS':'defaults'}))
            with self.assertRaises(PreflightCaptured):manager.sync(root,effective,runner=runner,mm=self.work/'unused-micromamba')
        args=captured['argv'];env=captured['env']
        self.assertIn('--no-rc',args);self.assertIn('--override-channels',args);self.assertIn('--dry-run',args)
        self.assertEqual([args[i+1] for i,x in enumerate(args) if x=='-c'],['conda-forge','my-lab'])
        self.assertNotIn('MAMBA_CHANNELS',env);self.assertNotIn('CONDA_CHANNELS',env)
        self.assertIn('pytorch',args);self.assertNotIn('pytorch-cpu',args);self.assertNotIn('pytorch-gpu',args)
    def test_preview_accepts_reordered_and_alternate_media_requests(self):
        import io
        spec=importlib.util.spec_from_file_location('preview_install',ROOT/'linux/science-install.py')
        install=importlib.util.module_from_spec(spec);spec.loader.exec_module(install)
        effective=dict(config.read_json(ROOT/'linux/science-installer-release.json'),**config.defaults(ROOT/'linux'))
        effective['ScientificPackages'].reverse()
        effective['ScientificPackages']=["opencv[version='5.0.0',build='qt6*']" if config.spec_name(x)=='opencv' else x for x in effective['ScientificPackages']]
        output=io.StringIO()
        with patch.object(install,'current_versions',return_value={name:'absent' for name in ['micromamba','python','spyder','opencv','ffmpeg']}), patch.object(install.m,'records',return_value={}), contextlib.redirect_stdout(output):
            self.assertEqual(install.preflight('Recommended',self.work/'root',self.work/'mm',effective,None),'Fresh installation')
        self.assertIn("opencv[version='5.0.0',build='qt6*']",output.getvalue())

    def test_invalid_legacy_structure_and_numeric_version_are_clear_errors(self):
        for document in [None, {'ScientificPackages':['numpy'], 'Python':3.14}]:
            source=self.work/'legacy-bad.json';source.write_text(json.dumps(document))
            with self.assertRaises(config.ConfigError):config.initialize(ROOT/'linux',path=self.work/'missing/active.json',legacy=source)
            self.assertEqual(source.read_text(),json.dumps(document))
    def test_install_entry_checks_integrity_before_loading_changed_code(self):
        import subprocess
        copy=self.work/'copy';shutil.copytree(ROOT/'linux',copy/'linux');shutil.copytree(ROOT/'shared',copy/'shared')
        path=copy/'linux/science-manager.py';path.write_text("raise RuntimeError('MUST NOT LOAD')\n"+path.read_text())
        result=subprocess.run([sys.executable,'-B',str(copy/'linux/science-install.py'),'--help'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SHA256 mismatch',result.stderr+result.stdout)
        self.assertNotIn('MUST NOT LOAD',result.stderr+result.stdout)
    @unittest.skipUnless(os.environ.get('SCIENCE_TEST_PWSH') or shutil.which('pwsh'), 'PowerShell runtime not available')
    def test_windows_entry_rejects_tamper_before_helper_execution(self):
        import subprocess
        executable=os.environ.get('SCIENCE_TEST_PWSH') or shutil.which('pwsh')
        copy=self.work/'windows-entry';shutil.copytree(ROOT/'windows',copy/'windows');shutil.copytree(ROOT/'shared',copy/'shared')
        common=copy/'windows/science-common.ps1';schema=copy/'shared/science-release.schema.json'
        marker=self.work/'MUST_NOT_RUN'
        env=dict(os.environ,XDG_CACHE_HOME=str(self.work/'cache'),XDG_CONFIG_HOME=str(self.work/'config'),XDG_DATA_HOME=str(self.work/'data'),LOCALAPPDATA=str(self.work/'local'))
        for target in [common,schema]:
            with self.subTest(component=target.name):
                original=target.read_bytes()
                if target==common: target.write_bytes(original+("\n[IO.File]::WriteAllText('"+str(marker)+"','BAD')\n").encode())
                else: target.write_bytes(original+b' ')
                result=subprocess.run([executable,'-NoLogo','-NoProfile','-File',str(copy/'windows/00-menu.ps1')],env=env,capture_output=True,text=True,timeout=30)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('SHA256 mismatch',result.stdout+result.stderr)
                self.assertFalse(marker.exists())
                target.write_bytes(original)
    def test_all_python_sources_parse(self):
        for path in (ROOT/'linux').glob('*.py'):ast.parse(path.read_text())

if __name__=='__main__':unittest.main(verbosity=2)
