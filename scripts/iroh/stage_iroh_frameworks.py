#!/usr/bin/env python3
"""Give Iroh its own module map in each Apple SDK's build directory."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

build, headers, stage, output = map(Path, sys.argv[1:])
args = ['xcodebuild', '-create-xcframework']
for target, platform, sdk in [
    ('aarch64-apple-darwin', 'MacOSX', 'macosx'),
    ('aarch64-apple-ios', 'iPhoneOS', 'iphoneos'),
    ('aarch64-apple-ios-sim', 'iPhoneSimulator', 'iphonesimulator'),
]:
    framework = stage / target / 'Iroh.framework'
    root = framework / 'Versions/A' if sdk == 'macosx' else framework
    root.mkdir(parents=True)
    info = root / 'Resources/Info.plist' if sdk == 'macosx' else root / 'Info.plist'
    info.parent.mkdir(exist_ok=True)
    with info.open('wb') as dest:
        plistlib.dump({
            'CFBundleIdentifier': 'computer.n0.Iroh',
            'CFBundleName': 'Iroh', 'CFBundleExecutable': 'Iroh',
            'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1.1.0',
            'CFBundleSupportedPlatforms': [platform], 'DTPlatformName': sdk,
            'MinimumOSVersion': '15.0' if sdk == 'macosx' else '17.5',
        }, dest)
    archive = build / target / 'release/libiroh_ffi.a'
    if sdk == 'iphonesimulator':
        subprocess.run(['lipo', '-create', str(archive),
                        str(build / 'x86_64-apple-ios/release/libiroh_ffi.a'),
                        '-output', str(root / 'Iroh')], check=True)
    else:
        shutil.copy2(archive, root / 'Iroh')
    shutil.copytree(headers, root / 'Headers', ignore=shutil.ignore_patterns('module.modulemap'))
    (root / 'Modules').mkdir()
    (root / 'Modules/module.modulemap').write_text('framework module Iroh { umbrella header "Export.h" export * }\n')
    if sdk == 'macosx':
        (framework / 'Versions/Current').symlink_to('A')
        for part in ['Headers', 'Modules', 'Resources', 'Iroh']:
            (framework / part).symlink_to(f'Versions/Current/{part}')
    args += ['-framework', str(framework)]
subprocess.run(args + ['-output', str(output)], check=True)
