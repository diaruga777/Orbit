#!/usr/bin/env python3
"""Package a committed phone project and its native archives for offline Mac setup."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def package(destination):
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    revision = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    # Only reviewed, committed files. Never include Local.xcconfig, credentials,
    # user state, derived data, or the publisher's signing material.
    files = subprocess.check_output(['git','ls-tree','-r','--name-only','HEAD'],cwd=ROOT,text=True).splitlines()
    include = [name for name in files if name.startswith(('Apps/Orbit/', 'Apps/OrbitWidgets/', 'Apps/OrbitUITests/', 'Tests/', 'Orbit.xcodeproj/', 'Sources/', 'Vendor/DeviceGateway/')) or name in {'Package.swift','Package.resolved','Config/Orbit.xcconfig','.gitignore','LICENSE','THIRD_PARTY_NOTICES.md'}]
    archive = destination / 'OrbitPhoneSource.zip'
    subprocess.run(['git','archive','--format=zip','-o',str(archive),'HEAD','--',*include],cwd=ROOT,check=True)
    with zipfile.ZipFile(archive,'a',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as output:
        for folder in ['Vendor/OrbitNet.xcframework','Vendor/DeviceGateway/IDevice.xcframework']:
            source = ROOT/folder
            if not source.is_dir():
                raise RuntimeError('Run bootstrap before packaging: '+folder)
            for file in sorted(source.rglob('*')):
                if file.is_symlink():
                    raise RuntimeError('Native payload contains a symlink: '+str(file))
                if file.is_file(): output.write(file,file.relative_to(ROOT))
    hasher = hashlib.sha256()
    with archive.open('rb') as file:
        while True:
            block = file.read(1024 * 1024)
            if not block: break
            hasher.update(block)
    digest = hasher.hexdigest()
    (destination/'OrbitPhoneSource.json').write_text(json.dumps({'revision':revision,'sha256':digest},indent=2)+'\n')
    return archive

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('destination',type=Path)
    print(package(parser.parse_args().destination))
