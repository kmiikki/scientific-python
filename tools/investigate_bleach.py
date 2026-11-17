#!/usr/bin/env python3
"""Bounded analysis only: four fresh dry runs; no installs or existing prefixes."""
from pathlib import Path
import datetime,hashlib,json,os,shutil,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/bleach-evidence';MM=os.environ.get('SCIENCE_TEST_MICROMAMBA') or shutil.which('micromamba')
def dump(path,data):path.write_text(json.dumps(data,indent=2)+'\n')
def main():
    if set(subprocess.check_output(['findmnt','-n','-T','/tmp','-o','FSTYPE'],text=True).split())!={'tmpfs'}:raise RuntimeError('/tmp must be tmpfs')
    if shutil.disk_usage('/tmp').free<4*1024**3:raise RuntimeError('Not enough free tmpfs capacity')
    OUT.mkdir(parents=True,exist_ok=True)
    base=json.loads((ROOT/'shared/science-release.default.json').read_text())['ScientificPackages']
    summary={'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'micromamba':subprocess.check_output([MM,'--version'],text=True).strip(),'fresh_solves_only':True,'cases':[]}
    with tempfile.TemporaryDirectory(prefix='science-bleach-',dir='/tmp') as td:
        temp=Path(td);roots={}
        for platform in ['linux-64','win-64']:
            root=temp/platform;cache=root/'pkgs/cache';cache.parent.mkdir(parents=True)
            previous=Path('/tmp/scientific-python-analysis-20261117/roots')/platform/'pkgs/cache'
            if previous.is_dir():shutil.copytree(previous,cache)
            roots[platform]=root
        cases=[('linux-current-seven','linux-64',[]),('linux-with-bleach64','linux-64',['bleach=6.4.0','bleach-with-css=6.4.0']),('linux-with-tinycss14','linux-64',['tinycss2=1.4.0']),('windows-current-seven','win-64',[])]
        refreshed=set()
        for name,platform,extra in cases:
            env={k:v for k,v in os.environ.items() if not k.startswith(('CONDA_','MAMBA_','PYTHON'))}
            env.update(CONDA_OVERRIDE_CUDA='',CONDA_OVERRIDE_GLIBC='2.39',CONDA_PKGS_DIRS=str(roots[platform]/'pkgs'),XDG_CACHE_HOME=str(temp/'xdg'),TMPDIR=str(temp))
            requests=list(base)
            if platform=='win-64':requests=[s.replace('>=9.0.2,<10','>=9.0.1,<10') if s.startswith('ffmpeg[') else s for s in requests]
            args=[MM,'create','--no-rc','--override-channels','-c','conda-forge','--strict-channel-priority','--platform',platform,'-r',str(roots[platform]),'-p',str(temp/'prefixes'/name),'--dry-run','--json','--repodata-ttl','0' if platform not in refreshed else '3600',*requests,*extra]
            start=time.monotonic();p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=240);refreshed.add(platform)
            (OUT/(name+'.json')).write_text(p.stdout);(OUT/(name+'.stderr')).write_text(p.stderr)
            data=json.loads(p.stdout);rows=data.get('actions',{}).get('LINK',[])
            selected={x['name']:{k:x.get(k) for k in ['version','build','depends','constrains','url','sha256']} for x in rows if x['name'] in ['bleach','bleach-with-css','tinycss2','optuna']}
            references=[]
            for row in rows:
                for field in ['depends','constrains']:
                    for req in row.get(field,[]) or []:
                        if req.split()[0] in ['bleach','bleach-with-css','tinycss2']:references.append({'package':row['name'],'field':field,'request':req})
            item={'id':name,'command':args,'seconds':round(time.monotonic()-start,2),'success':p.returncode==0 and data.get('success') is True,'exit_code':p.returncode,'selected':selected,'references':references,'solver_problems':data.get('solver_problems')}
            summary['cases'].append(item);dump(OUT/'summary.json',summary)
            print(name,item['success'],{k:v['version'] for k,v in selected.items()},flush=True)
        summary['metadata_state']={platform:{p.name:p.read_text() for p in (root/'pkgs/cache').glob('*.state.json')} for platform,root in roots.items()}
    summary['temporary_roots_cleaned']=not temp.exists();summary['finished_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat();dump(OUT/'summary.json',summary)
if __name__=='__main__':main()
