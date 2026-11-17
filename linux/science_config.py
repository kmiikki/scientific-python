"""Schema v1, conservative legacy migration, and stable per-user configuration.
No dependency solver. MatchSpec semantics are checked by Micromamba preflight.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

class ConfigError(ValueError):
    pass

def shared(directory):
    directory=Path(directory)
    return directory/'shared' if (directory/'shared').is_dir() else directory.parent/'shared'

def _pairs(items):
    value={}
    for key,item in items:
        if key in value:raise ConfigError('Duplicate JSON key: '+key)
        value[key]=item
    return value

def _plain_path(path):
    for item in [Path(path), *Path(path).parents]:
        if item.is_symlink(): raise ConfigError('Redirected configuration path refused: '+str(item))

def read_json(path):
    try:
        p=Path(path)
        _plain_path(p)
        if p.is_symlink() or not p.is_file():raise ConfigError('Configuration must be a regular file: '+str(p))
        return json.loads(p.read_text(encoding='utf-8-sig'),object_pairs_hook=_pairs,parse_constant=lambda x:(_ for _ in ()).throw(ConfigError('Invalid JSON constant: '+x)))
    except (OSError,UnicodeError,json.JSONDecodeError) as e:raise ConfigError('Cannot read JSON '+str(path)+': '+str(e)) from e

def spec_name(spec,channels=None):
    if not isinstance(spec,str) or not spec or spec!=spec.strip() or any(ord(c)<32 for c in spec):raise ConfigError('Package request must be a nonempty string without surrounding whitespace or control characters.')
    match=re.fullmatch(r'(?:(?P<channel>[^\s]+)::)?(?P<name>[A-Za-z0-9_][A-Za-z0-9_.-]*)(?P<tail>.*)',spec)
    if not match:raise ConfigError('Invalid package request: '+spec)
    if channels is not None and match['channel'] and match['channel'] not in channels:raise ConfigError('Package channel is not in Channels: '+spec)
    tail=match['tail']
    if tail and not (tail[0] in '[=<>!~ '):raise ConfigError('Invalid MatchSpec after package name: '+spec)
    quote=None;depth=0
    for c in tail:
        if c in "'\"":
            if quote==c:quote=None
            elif quote is None:quote=c
        elif quote is None:
            if c=='[':depth+=1
            elif c==']':depth-=1
            if depth not in (0,1):raise ConfigError('Unbalanced MatchSpec brackets: '+spec)
    if quote is not None or depth:raise ConfigError('Unbalanced MatchSpec quotes/brackets: '+spec)
    if tail and tail.strip() in ('=','==','>=','<=','>','<','!=','~=','[]'):raise ConfigError('Missing MatchSpec constraint: '+spec)
    # Attribute-qualified channels must be explicit too. Other native attributes are left to Micromamba.
    for channel in re.findall(r'(?:\[|,)\s*channel\s*=\s*[\'\"]?([^,\]\'\" ]+)',tail):
        if channels is not None and channel not in channels:raise ConfigError('Package channel is not in Channels: '+channel)
    return match['name'].lower()

def validate(value,directory):
    schema=read_json(shared(directory)/'science-release.schema.json')
    if not isinstance(value,dict) or set(value)!=set(schema['required']):raise ConfigError('Expected only SchemaVersion, Channels and ScientificPackages.')
    if type(value['SchemaVersion']) is not int or value['SchemaVersion']!=1:raise ConfigError('Unsupported SchemaVersion; expected integer 1.')
    for field in ('Channels','ScientificPackages'):
        values=value[field]
        if not isinstance(values,list) or not values or any(not isinstance(x,str) or not x or x!=x.strip() or any(ord(c)<32 for c in x) for x in values):raise ConfigError(field+' must be a nonempty list of nonempty strings.')
        if len(values)!=len(set(values)):raise ConfigError('Duplicate entry in '+field+'.')
    for channel in value['Channels']:
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_./-]*|https://[^\s\[\]<>]+',channel):raise ConfigError('Invalid channel name or HTTPS URL: '+channel)
    names={}
    for i,spec in enumerate(value['ScientificPackages']):
        name=spec_name(spec,value['Channels'])
        if name in names:raise ConfigError('Duplicate/conflicting package '+name+' at ScientificPackages['+str(i)+']; use one request per package.')
        names[name]=spec
    return value

def defaults(directory):
    return validate(read_json(shared(directory)/'science-release.default.json'),directory)

def active_path():
    return Path(os.environ.get('XDG_CONFIG_HOME',str(Path.home()/'.config')))/'scientific-python/science-release.json'

def _foundation(old):
    for key in ('Python','Spyder','OpenCV','OpenCVMaxExclusive','FFmpeg','FFmpegMaxExclusive'):
        if key not in old or not isinstance(old[key],str) or not re.fullmatch(r'\d+(?:\.\d+){0,3}',str(old[key])):raise ConfigError('Legacy configuration has invalid/missing '+key+'.')
    arrow=old.get('ArrowVariant','cpu')
    if not isinstance(arrow,str) or not re.fullmatch(r'[A-Za-z0-9_*.-]+',arrow):raise ConfigError('Invalid legacy ArrowVariant.')
    return ['python='+old['Python'],'python_abi='+old['Python']+'=*_cp'+old['Python'].replace('.',''),'spyder='+old['Spyder'],'apache-arrow-proc=*='+arrow,"opencv[version='>="+old['OpenCV']+',<'+old['OpenCVMaxExclusive']+"',build='qt6*']","ffmpeg[version='>="+old['FFmpeg']+',<'+old['FFmpegMaxExclusive']+"',build='gpl*']"]

def migrate(value,directory):
    if not isinstance(value,dict):raise ConfigError('Configuration must be a JSON object.')
    if 'SchemaVersion' in value:return validate(value,directory)
    if not isinstance(value,dict) or not isinstance(value.get('ScientificPackages'),list):raise ConfigError('Legacy package list is missing; restore the original science-release.json. Installed packages cannot establish user intent.')
    packages=value['ScientificPackages']
    names={spec_name(x) for x in packages}
    result={'SchemaVersion':1,'Channels':value.get('Channels',['conda-forge']),'ScientificPackages':[x for x in _foundation(value) if spec_name(x) not in names]+packages}
    return validate(result,directory)

def atomic_write(path,content):
    path=Path(path)
    _plain_path(path)
    if path.is_symlink():raise ConfigError('Refusing symlink configuration: '+str(path))
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.science-config-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as stream:stream.write(content);stream.flush();os.fsync(stream.fileno())
        os.chmod(tmp,0o600);os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def _origin_known(path,root):
    receipt=Path(path).with_name('science-config-origins.json')
    value=read_json(receipt) if receipt.exists() or receipt.is_symlink() else {'SchemaVersion':1,'Roots':[]}
    if not isinstance(value,dict) or set(value)!={'SchemaVersion','Roots'} or value['SchemaVersion']!=1 or not isinstance(value['Roots'],list) or any(not isinstance(x,str) for x in value['Roots']):
        raise ConfigError('Invalid configuration origin record; restore the original configuration metadata. No environment changes started.')
    return receipt,value,str(Path(root).resolve())

def _bind_origin(path,root):
    if root is None:return
    receipt,value,key=_origin_known(path,root)
    if key not in value['Roots']:
        value['Roots'].append(key)
        atomic_write(receipt,(json.dumps(value,indent=2)+'\n').encode())

def initialize(directory,root=None,path=None,legacy=None):
    """Never infer requested packages from installed package metadata."""
    directory=Path(directory);path=Path(path) if path is not None else active_path()
    existing=root is not None and (Path(root)/'envs/science').exists()
    if root is not None: _origin_known(path,root)
    if legacy is not None and not Path(legacy).is_file() and not path.exists(): raise ConfigError('Explicit legacy configuration is missing; migration stopped.')
    candidates=[path]
    if legacy is not None:candidates.append(Path(legacy))
    candidates.append(directory/'science-release.json')
    if root is not None:candidates.append(Path(root)/'share/scientific-python/science-release.json')
    source=next((p for p in candidates if p.exists() or p.is_symlink()),None)
    if source is None:
        if existing:raise ConfigError('Existing Science environment has no recoverable original configuration. Restore science-release.json; migration stopped and the environment was not changed.')
        value=defaults(directory)
    else:
        old=read_json(source);value=migrate(old,directory)
        if source==path and 'SchemaVersion' in old:
            if existing:
                _,origins,key=_origin_known(path,root)
                if key not in origins['Roots']:
                    previous=next((p for p in candidates[1:] if p.exists() or p.is_symlink()),None)
                    if previous is None or migrate(read_json(previous),directory)!=value:
                        raise ConfigError('Existing Science environment has no matching original configuration for this active file. Restore its original science-release.json; migration stopped without changing configuration or environment.')
            _bind_origin(path,root)
            return value
        original=source.read_bytes();digest=hashlib.sha256(original).hexdigest()
        backup=path.parent/('science-release.legacy-'+digest+'.json')
        if backup.exists():
            if backup.is_symlink() or backup.read_bytes()!=original:raise ConfigError('Legacy backup collision: '+str(backup))
        else:atomic_write(backup,original)
    atomic_write(path,(json.dumps(value,indent=2,ensure_ascii=False)+'\n').encode('utf-8'))
    _bind_origin(path,root)
    return value

def effective(directory,path=None):
    directory=Path(directory);path=Path(path) if path is not None else active_path()
    user=migrate(read_json(path),directory) if path.exists() or path.is_symlink() else defaults(directory)
    policy=read_json(directory/'science-installer-release.json')
    return dict(policy,**user)

def require_workflow(config):
    required=('python','python_abi','spyder','apache-arrow-proc','opencv','ffmpeg')
    names={spec_name(s) for s in config['ScientificPackages']}
    missing=set(required)-names
    if missing:raise ConfigError('This installer phase requires foundation packages: '+', '.join(sorted(missing))+'. Configuration is preserved; no package changes started.')
