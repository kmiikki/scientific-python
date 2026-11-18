#!/usr/bin/env python3
"""Read-only public-source audit; no environment install, removal or network calls."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT=Path(__file__).resolve().parents[1]
ROOT_FILES={'.gitattributes','.gitignore','README.md','LICENSE','CHANGELOG.md','THIRD_PARTY_NOTICES.md','SOURCE-SHA256SUMS.txt'}
PUBLIC_DIRS={'linux','windows','shared','tests','tools','docs'}

def public_files(root=ROOT):
    paths=[]
    for path in root.rglob('*'):
        relative=path.relative_to(root)
        if not path.is_file() or '__pycache__' in relative.parts:continue
        if len(relative.parts)==1 and path.name in ROOT_FILES or relative.parts[0] in PUBLIC_DIRS:
            paths.append(path)
    return sorted(paths, key=lambda path: path.relative_to(root).as_posix())

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def source_manifest(root=ROOT):
    return ''.join(digest(p)+'  '+p.relative_to(root).as_posix()+'\n' for p in public_files(root) if p.name!='SOURCE-SHA256SUMS.txt')

def audit(root=ROOT):
    files=public_files(root);errors=[];checks={}
    expected=source_manifest(root)
    checks['source_manifest']=(root/'SOURCE-SHA256SUMS.txt').read_text()==expected
    if not checks['source_manifest']:errors.append('Source manifest is stale or incomplete')
    for platform in ['linux','windows']:
        base=root/platform
        names=set()
        for line in (base/'SHA256SUMS.txt').read_text().splitlines():
            sha,name=line.split('  ',1);names.add(name)
            path=root/name if name.startswith('shared/') else base/name
            if name=='science-release.json' or not path.is_file() or digest(path)!=sha:errors.append('Invalid platform manifest entry: '+platform+'/'+name)
        expected_names={p.relative_to(base).as_posix() for p in files if p.is_relative_to(base) and p.name!='SHA256SUMS.txt'}
        expected_names|={'shared/'+p.relative_to(root/'shared').as_posix() for p in files if p.is_relative_to(root/'shared')}
        if names!=expected_names:errors.append('Incomplete platform manifest: '+platform)
    checks['platform_manifests']=not any('platform manifest' in x for x in errors)
    for path in files:
        relative=path.relative_to(root).as_posix()
        if path.is_symlink():errors.append('Public symlink: '+relative)
        if path.stat().st_size>1024*1024:errors.append('Large public file: '+relative)
        if path.suffix.lower() in {'.zip','.exe','.dll','.conda','.bz2','.key','.pem'}:errors.append('Unexpected binary/secret file: '+relative)
        data=path.read_bytes()
        try:text=data.decode('utf-8-sig')
        except UnicodeDecodeError:errors.append('Unexpected non-text source: '+relative);continue
        # Match actual values, not variable names such as password or startup token.
        for pattern in [r'-----BEGIN [A-Z ]*PRIVATE KEY-----',r'gh[pousr]_[A-Za-z0-9]{30,}',r'github_pat_[A-Za-z0-9_]{30,}',r'AKIA[A-Z0-9]{16}',r'\bsk-[A-Za-z0-9_-]{30,}',re.escape(str(Path.home()))+r'(?:[/\\]|\b)']:
            # Scanner patterns naturally occur in this audit tool; skip its definitions.
            if path==Path(__file__).resolve():continue
            if re.search(pattern,text):errors.append('Potential credential/personal path: '+relative)
        if path.suffix=='.py':
            try:ast.parse(text,filename=relative)
            except SyntaxError as exc:errors.append(str(exc))
        if path.suffix=='.sh':
            p=subprocess.run(['bash','-n',str(path)],capture_output=True,text=True)
            if p.returncode:errors.append(relative+': '+p.stderr)
        if path.suffix=='.ps1' and '\ufeff' in text:errors.append('Embedded BOM: '+relative)
        if path.suffix=='.md':
            for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)',text):
                target=target.split(' "',1)[0].strip('<>')
                if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:',target) or target.startswith('#'):continue
                link=unquote(target.split('#',1)[0])
                if link and not (path.parent/link).is_file():errors.append('Broken Markdown link: '+relative+' -> '+target)
                elif link and (path.parent/link).resolve() not in {p.resolve() for p in files}:errors.append('Link outside public files: '+relative+' -> '+target)
    checks['public_file_count']=len(files)
    checks['public_bytes']=sum(p.stat().st_size for p in files)
    checks['markdown_files']=[p.relative_to(root).as_posix() for p in files if p.suffix=='.md']
    # These commands only display help or return from the menu.
    for label,args,stdin in [('installer_help',[sys.executable,'-B',str(root/'linux/science-install.py'),'--help'],None),('menu_quit',['bash',str(root/'linux/00-menu.sh')],'q\n'),('config_location',['bash',str(root/'linux/00-menu.sh')],'c\nq\n')]:
        p=subprocess.run(args,input=stdin,capture_output=True,text=True,timeout=20)
        checks[label]=p.returncode==0
        if p.returncode:errors.append(label+': '+p.stderr)
    checks['bash_syntax_files']=sum(p.suffix=='.sh' for p in files)
    checks['errors']=errors;checks['pass']=not errors
    return checks

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--refresh-source',action='store_true',help='Maintainer-only source-manifest regeneration');args=parser.parse_args()
    if args.refresh_source:(ROOT/'SOURCE-SHA256SUMS.txt').write_bytes(source_manifest().encode('ascii'))
    result=audit();print(json.dumps(result,indent=2));return 0 if result['pass'] else 1
if __name__=='__main__':raise SystemExit(main())
