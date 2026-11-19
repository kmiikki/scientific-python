#!/usr/bin/env python3
"""Build verified local installer ZIPs for Ubuntu and Windows."""
import argparse
import json
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile

from audit_release import ROOT, audit, public_files

PLATFORMS = ('linux', 'windows')


def release_version(root):
    versions = [json.loads((root / platform / 'science-installer-release.json').read_text())['InstallerVersion']
                for platform in PLATFORMS]
    if versions[0] != versions[1] or not re.fullmatch(r'\d+\.\d+\.\d+', versions[0]):
        raise ValueError('Windows and Ubuntu must declare the same Scientific Python version.')
    return versions[0]


def build(root, output):
    version = release_version(root)
    checks = audit(root)
    if not checks['pass']:
        raise ValueError('\n'.join(checks['errors']))
    output.mkdir(parents=True, exist_ok=True)
    files = [path.relative_to(root) for path in public_files(root)]
    archives = []
    for platform in PLATFORMS:
        name = f'scientific-python-v{version}-{platform}'
        path = output / (name + '.zip')
        with ZipFile(path, 'x', ZIP_DEFLATED) as archive:
            for entry in files:
                if entry.parts[0] in (platform, 'shared', 'LICENSE', 'THIRD_PARTY_NOTICES.md'):
                    archive.write(root / entry, (Path(name) / entry).as_posix())
        archives.append(path)
    return archives


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='Directory for the two local ZIP archives.')
    args = parser.parse_args()
    try:
        for path in build(ROOT, args.output):
            print(path)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
