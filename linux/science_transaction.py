"""Bind package transactions to approved identities and verified local archives."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import urllib.parse
import urllib.request

FIELDS=('name','version','build','subdir','sha256')


class TransactionError(RuntimeError):
    pass


def identity(record):
    value={key:record.get(key) for key in FIELDS}
    value['build']=record.get('build',record.get('build_string'))
    for key in ['name','version','build']:
        if not isinstance(value[key],str) or not value[key] or not re.fullmatch(r'[A-Za-z0-9_.+!-]+',value[key]):
            raise TransactionError('Invalid package '+key+': '+repr(value[key]))
    if value['subdir'] not in ['linux-64','noarch']:
        raise TransactionError('Missing/unsupported platform for '+value['name'])
    if not isinstance(value['sha256'],str) or not re.fullmatch('[0-9a-f]{64}',value['sha256']):
        raise TransactionError('Missing/invalid SHA-256 for '+value['name'])
    return value


def indexed(records):
    result={}
    for record in records:
        item=identity(record)
        if item['name'] in result:raise TransactionError('Duplicate package in transaction: '+item['name'])
        result[item['name']]=item
    return result


def signature(plan):
    actions=plan.get('actions') or {}
    if not plan.get('success'):raise TransactionError('Transaction did not report success.')
    return {key:indexed(actions.get(key,[])) for key in ['LINK','UNLINK']}


def differences(expected,actual):
    result=[]
    for name in sorted(set(expected)|set(actual)):
        old=expected.get(name);new=actual.get(name)
        if old!=new:result.append({'name':name,'approved':old,'actual':new})
    return result


def format_identity(record):
    if record is None:return 'not present'
    return '{version} {build} [{subdir}] sha256={sha256}'.format(**record)


def assert_transaction(approved,actual,stage):
    old=signature(approved);new=signature(actual);messages=[]
    for action in ['LINK','UNLINK']:
        for item in differences(old[action],new[action]):
            messages.append(action+' '+item['name']+': approved '+format_identity(item['approved'])+'; actual '+format_identity(item['actual']))
    if messages:
        error=TransactionError(stage+' differs from approved transaction:\n'+'\n'.join(messages))
        error.differences={key:differences(old[key],new[key]) for key in ['LINK','UNLINK']}
        raise error


def assert_prefix(plan,prefix,stage):
    values=[plan.get('prefix'),(plan.get('actions') or {}).get('PREFIX')]
    if any(not isinstance(value,str) or Path(value)!=Path(prefix) for value in values if value is not None):
        raise TransactionError(stage+' reports a different target prefix; no alternative target is allowed.')


def assert_installed(expected,actual):
    delta=differences(indexed(expected),indexed(actual))
    if delta:raise TransactionError('Installed state differs from approved lock:\n'+'\n'.join(item['name']+': approved '+format_identity(item['approved'])+'; actual '+format_identity(item['actual']) for item in delta))


def canonical_json(value):return json.dumps(value,sort_keys=True,separators=(',',':')).encode()
def digest(value):return hashlib.sha256(canonical_json(value)).hexdigest()


def artifact(record):
    item=identity(record)
    url=record.get('url');filename=record.get('fn')
    if not isinstance(url,str):raise TransactionError('Missing artifact URL for '+item['name'])
    parsed=urllib.parse.urlsplit(url)
    if parsed.scheme!='https' or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise TransactionError('Unapproved artifact URL format for '+item['name'])
    filename=filename or urllib.parse.unquote(parsed.path.rsplit('/',1)[-1])
    stem=item['name']+'-'+item['version']+'-'+item['build']
    if filename not in [stem+'.conda',stem+'.tar.bz2'] or urllib.parse.unquote(parsed.path.rsplit('/',1)[-1])!=filename:
        raise TransactionError('Artifact filename disagrees with identity for '+item['name'])
    if parsed.path.split('/')[-2]!=item['subdir']:
        raise TransactionError('Artifact URL platform differs for '+item['name'])
    return dict(item,url=url,fn=filename,size=record.get('size',0) or 0)


def freeze(before,plan,prefix):
    approved=json.loads(json.dumps(plan));initial=indexed(before.values());actions=signature(approved)
    after=dict(before)
    for name,item in actions['UNLINK'].items():
        if initial.get(name)!=item:raise TransactionError('UNLINK does not match installed identity: '+name)
        after.pop(name,None)
    for record in approved.get('actions',{}).get('LINK',[]):
        artifact(record);after[record['name']]=record
    indexed(after.values())
    return {'schema':1,'prefix':str(prefix),'before':list(initial.values()),'after':list(indexed(after.values()).values()),
            'approved_plan':approved,'records_after':list(after.values()),
            'artifacts':[artifact(record) for record in approved.get('actions',{}).get('LINK',[])]}


def verify_file(path,record):
    if path.is_symlink() or not path.is_file():raise TransactionError('Approved archive missing: '+record['name']+' at '+str(path))
    with path.open('rb') as stream:actual=hashlib.file_digest(stream,'sha256').hexdigest()
    if actual!=record['sha256']:raise TransactionError('Archive SHA-256 mismatch for '+record['name']+': approved '+record['sha256']+', actual '+actual)


def cache_candidates(cache,record):
    # Never repair, chmod or delete shared caches. Candidates are read-only inputs.
    cache=Path(cache);parsed=urllib.parse.urlsplit(record['url'])
    result=[cache/record['fn'],cache/parsed.scheme/parsed.netloc/urllib.parse.unquote(parsed.path).lstrip('/')]
    return list(dict.fromkeys(result))


def stage_archives(lock,directory,cache,plain_path,fetch=None):
    directory=Path(directory)
    for record in lock['artifacts']:
        destination=directory/'channel'/record['subdir']/record['fn']
        plain_path(destination,missing=True)
        destination.parent.mkdir(parents=True,exist_ok=True)
        if destination.exists():verify_file(destination,record);continue
        selected=None
        for source in cache_candidates(cache,record):
            if source.is_file() and not source.is_symlink():
                try:plain_path(source);verify_file(source,record);selected=source;break
                except (OSError,TransactionError,RuntimeError):continue
        fd,temp=tempfile.mkstemp(prefix='.artifact-',dir=destination.parent)
        os.close(fd);temporary=Path(temp)
        try:
            if selected:shutil.copyfile(selected,temporary)
            elif fetch:fetch(record['url'],temporary)
            else:
                with urllib.request.urlopen(record['url'],timeout=120) as response,temporary.open('wb') as stream:
                    shutil.copyfileobj(response,stream)
            verify_file(temporary,record)
            temporary.chmod(0o444);os.replace(temporary,destination)
        finally:
            if temporary.exists():temporary.unlink()
    return [directory/'channel'/record['subdir']/record['fn'] for record in lock['artifacts']]


def verify_archives(lock,directory):
    for record in lock['artifacts']:verify_file(Path(directory)/'channel'/record['subdir']/record['fn'],record)


def explicit_text(lock,directory):
    return '# platform: linux-64\n@EXPLICIT\n'+''.join((Path(directory)/'channel'/r['subdir']/r['fn']).as_uri()+'#'+r['sha256']+'\n' for r in lock['artifacts'])


def write_locked_channel(lock,directory,plain_path):
    directory=Path(directory);channel=directory/'channel'
    for subdir in ['linux-64','noarch']:
        target=channel/subdir;plain_path(target,missing=True);target.mkdir(parents=True,exist_ok=True)
        repodata={'info':{'subdir':subdir},'packages':{},'packages.conda':{},'repodata_version':1}
        for record in lock['records_after']:
            item=identity(record)
            if item['subdir']!=subdir:continue
            filename=record.get('fn') or urllib.parse.unquote(urllib.parse.urlsplit(record.get('url','')).path.rsplit('/',1)[-1])
            if not filename:raise TransactionError('Missing installed filename for '+item['name'])
            row={key:record[key] for key in ['name','version','build','build_number','depends','constrains','license','noarch','timestamp','size','md5','sha256','subdir'] if key in record and record[key] is not None}
            row.update(item);row.setdefault('build_number',0);row.setdefault('depends',[]);row.setdefault('constrains',[])
            row.pop('url',None)
            repodata['packages.conda' if filename.endswith('.conda') else 'packages'][filename]=row
        plain_path(target/'repodata.json',missing=True)
        (target/'repodata.json').write_text(json.dumps(repodata,sort_keys=True)+'\n')
    specs=[item['name']+"[version='=="+item['version']+"',build='"+item['build']+"',subdir='"+item['subdir']+"',sha256='"+item['sha256']+"']" for item in lock['after']]
    environment={'channels':[channel.as_uri()],'dependencies':specs}
    path=directory/'locked-environment.yml';plain_path(path,missing=True);path.write_text(json.dumps(environment,indent=2)+'\n');return path


def apply(lock,directory,mm,root,env,runner,parse_plan,check_state,before_commit,write_json,plain_path,prepare_prefix):
    """No free online/offline solve after approval; every dry run/action is checked."""
    directory=Path(directory);plain_path(directory);plain=directory/'explicit-local.txt';plain_path(plain,missing=True);plain.write_text(explicit_text(lock,directory))
    lock_path=directory/'approved-lock.json';plain_path(lock_path);lock_bytes=lock_path.read_bytes()
    if json.loads(lock_bytes)!=lock:raise TransactionError('Approved lock changed before preparation.')
    lock_hash=hashlib.sha256(lock_bytes).hexdigest()
    immutable_files={plain:plain.read_bytes()}
    def guard():
        if hashlib.sha256(lock_path.read_bytes()).hexdigest()!=lock_hash:raise TransactionError('Approved lock changed after approval.')
        for path,content in immutable_files.items():
            if path.is_symlink() or path.read_bytes()!=content:raise TransactionError('Locked transaction input changed: '+str(path))
        verify_archives(lock,directory);check_state()
    def execute(argv,phase):
        result=runner(argv,env=env)
        if result.returncode:
            print(result.stdout,end='');print(result.stderr,end='')
            error=TransactionError(phase+' failed (exit '+str(result.returncode)+'); no alternative plan was accepted.')
            error.rollback_reported='rolled back' in (result.stdout+result.stderr).lower()
            raise error
        plan=parse_plan(result.stdout)
        assert_prefix(plan,argv[argv.index('-p')+1],phase)
        return plan
    # Download/extract only in a disposable prefix and private HOME. This does not
    # create, recreate or register the real science prefix before the commit.
    private_home=directory/'private-home';plain_path(private_home,missing=True);private_home.mkdir(exist_ok=True)
    download_env=env.copy();download_env.update(HOME=str(private_home),XDG_CONFIG_HOME=str(private_home/'.config'),XDG_DATA_HOME=str(private_home/'.local/share'),XDG_CACHE_HOME=str(private_home/'.cache'))
    download_prefix=Path(tempfile.mkdtemp(prefix='download-prefix-',dir=directory))
    preload=[mm,'create','--no-rc','-r',root,'-p',download_prefix,'--offline','--no-pyc','--json','--file',plain]
    guard()
    result=runner(preload+['--download-only','-y'],env=download_env)
    if result.returncode:
        print(result.stdout,end='');print(result.stderr,end='')
        raise TransactionError('Locked archive extraction failed before science package changes.')
    preload_plan=parse_plan(result.stdout)
    assert_prefix(preload_plan,download_prefix,'Explicit archive preparation')
    expected_links={'success':True,'actions':{'LINK':lock['approved_plan'].get('actions',{}).get('LINK',[])}}
    assert_transaction(expected_links,preload_plan,'Explicit archive preparation')
    prefix=Path(lock['prefix'])
    if lock['before']:
        environment=write_locked_channel(lock,directory,plain_path)
        immutable_files[environment]=environment.read_bytes()
        for subdir in ['linux-64','noarch']:
            path=directory/'channel'/subdir/'repodata.json';immutable_files[path]=path.read_bytes()
        # Explicit URL installs do not unlink old versions in these releases.
        # A complete, hash-pinned local universe retains normal atomic update /
        # prune semantics, with no other versions or remote channel available.
        command=[mm,'env','update','--prune','--no-rc','-r',root,'-p',prefix,'--offline','--json','--file',environment]
    else:
        prepare_prefix()
        command=[mm,'install','--no-rc','-r',root,'-p',prefix,'--offline','--no-pyc','--json','--file',plain]
    guard()
    preflight=execute(command+['--dry-run'],'Locked preflight')
    assert_transaction(lock['approved_plan'],preflight,'Locked preflight')
    write_json(directory/'locked-preflight.json',preflight)
    guard();before_commit()
    committed=execute(command+['-y'],'Locked transaction')
    assert_transaction(lock['approved_plan'],committed,'Committed transaction')
    write_json(directory/'committed-plan.json',committed)
    verify_archives(lock,directory)
    if hashlib.sha256(lock_path.read_bytes()).hexdigest()!=lock_hash:raise TransactionError('Lock changed during transaction.')
    for path,content in immutable_files.items():
        if path.is_symlink() or path.read_bytes()!=content:raise TransactionError('Locked transaction input changed during commit: '+str(path))
    return committed
