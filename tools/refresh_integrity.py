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
    for p in sorted(files,key=lambda p:p.relative_to(base).as_posix()):lines.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(base).as_posix())
    for p in sorted(shared,key=lambda p:p.relative_to(ROOT/'shared').as_posix()):lines.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  shared/'+p.relative_to(ROOT/'shared').as_posix())
    (base/'SHA256SUMS.txt').write_bytes(('\n'.join(lines)+'\n').encode('ascii'))
