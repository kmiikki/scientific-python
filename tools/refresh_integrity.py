#!/usr/bin/env python3
"""Maintainer-only regeneration after reviewed code changes; users never run this."""
from pathlib import Path
import hashlib
ROOT=Path(__file__).resolve().parents[1]
for platform in ('linux','windows'):
    base=ROOT/platform
    files=[p for p in base.rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.name not in ('SHA256SUMS.txt','science-release.json')]
    shared=[p for p in (ROOT/'shared').rglob('*') if p.is_file() and '__pycache__' not in p.parts]
    lines=[]
    for p in sorted(files):lines.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(base)))
    for p in sorted(shared):lines.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  shared/'+str(p.relative_to(ROOT/'shared')))
    (base/'SHA256SUMS.txt').write_text('\n'.join(lines)+'\n',encoding='ascii')
