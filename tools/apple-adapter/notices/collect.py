#!/usr/bin/env python3
"""Collect licenses for the pinned helper's Go modules before staging it."""
import json
import pathlib
import shutil
import subprocess
import sys

module = pathlib.Path(__file__).resolve().parents[1]
target = pathlib.Path(sys.argv[1])
target.mkdir(parents=True, exist_ok=True)
raw = subprocess.check_output(['go', '-C', str(module), 'list', '-deps', '-json', './cmd/orbit-apple-adapter'], text=True)
decoder = json.JSONDecoder()
modules = []
while raw.strip():
    raw = raw.lstrip()
    item, end = decoder.raw_decode(raw)
    dependency = item.get('Module')
    if dependency and not any(value['Path'] == dependency['Path'] for value in modules):
        modules.append(dependency)
    raw = raw[end:]
manifest = []
for item in modules:
    if item.get('Main'):
        continue
    root = item.get('Dir')
    if not root:
        raise SystemExit('Missing dependency source for license collection: ' + item['Path'])
    files = sorted({p for pattern in ('LICENSE*', 'LICENCE*', 'COPYING*', 'NOTICE*', 'PATENTS*')
                    for p in pathlib.Path(root).glob(pattern) if p.is_file()})
    if not files:
        raise SystemExit('Missing dependency license: ' + item['Path'])
    name = item['Path'].replace('/', '_')
    for source in files:
        shutil.copyfile(source, target / (name + '-' + source.name))
    manifest.append({'module': item['Path'], 'version': item['Version']})
root = pathlib.Path(subprocess.check_output(['go', 'env', 'GOROOT'], text=True).strip())
license_file = next((p for p in (root / 'LICENSE', root.parent / 'LICENSE') if p.is_file()), None)
if not license_file:
    raise SystemExit('Missing Go runtime license at the compiler installation')
shutil.copyfile(license_file, target / 'Go-LICENSE')
(target / 'modules.json').write_text(json.dumps(manifest, indent=2) + '\n')
