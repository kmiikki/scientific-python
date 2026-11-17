#!/usr/bin/env python3
"""Build tiny, inert noarch archives for the native Micromamba contract test."""
import hashlib,io,json,sys,tarfile
from pathlib import Path

def make(directory):
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=True)
    rows={}
    for name,version,build,depends in [('science-fixture-a','1.0','0',['science-fixture-b >=1']),('science-fixture-a','2.0','0',['science-fixture-b >=1']),('science-fixture-a','2.0','1',['science-fixture-b >=1']),('science-fixture-b','1.0','0',[]),('science-fixture-user','1.0','0',[])]:
        record=dict(name=name,version=version,build=build,build_number=int(build),depends=depends,subdir='noarch',noarch='generic',license='MIT')
        filename=f'{name}-{version}-{build}.tar.bz2';payload=f'share/{name}.txt'
        with tarfile.open(directory/filename,'w:bz2') as archive:
            for path,text in [('info/index.json',json.dumps(record)),('info/files',payload+'\n'),(payload,filename+'\n')]:
                data=text.encode();info=tarfile.TarInfo(path);info.size=len(data);info.mode=0o644;info.mtime=0;archive.addfile(info,io.BytesIO(data))
        record.update(fn=filename,url='https://example.invalid/noarch/'+filename,channel='https://example.invalid',sha256=hashlib.sha256((directory/filename).read_bytes()).hexdigest(),size=(directory/filename).stat().st_size)
        rows[name+'-'+version+'-'+build]=record
    (directory/'records.json').write_text(json.dumps(rows,indent=2)+'\n')
if __name__=='__main__':make(sys.argv[1])
