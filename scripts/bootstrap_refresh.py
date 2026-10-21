#!/usr/bin/env python3
"""Fetch the pinned device library and give its static frameworks unique headers.

Xcode flattens headers from archive-based XCFrameworks into include/. Wrapping
IDevice in static .framework bundles avoids collisions with Luna's Go bridge.
No signing keys, account access, phone connection or installed app is used.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
URL = 'https://github.com/SideStore/idevice/releases/download/v0.1.68-ss-3e55c84/idevice-xcframework-v0.1.68-ss-3e55c84.zip'
SHA256 = '445702d53942597deb4cdec2c4122d16a3f4ac124ce26cd75b68dab3dad92416'
OUTPUT = ROOT / 'Vendor/DeviceGateway/IDevice.xcframework'

def main():
    stamp = OUTPUT / '.orbit-source-sha256'
    if stamp.exists() and stamp.read_text().strip() == SHA256:
        print('Orbit refresh device library is ready.')
        return
    with tempfile.TemporaryDirectory(prefix='luna-refresh-dependency-') as directory:
        scratch = Path(directory).resolve()
        archive = scratch / 'IDevice.zip'
        cache = Path.home() / 'Library/Caches/org.swift.swiftpm/artifacts/https___github_com_SideStore_idevice_releases_download_v0_1_68_ss_3e55c84_idevice_xcframework_v0_1_68_ss_3e55c84_zip'
        if cache.exists():
            shutil.copy2(cache, archive)
        else:
            subprocess.run(['curl', '--fail', '--location', '--retry', '2', '--max-time', '180', URL, '-o', str(archive)], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
            raise RuntimeError('The device-library archive failed its checksum check.')
        with zipfile.ZipFile(archive) as package:
            for entry in package.infolist():
                target = (scratch / entry.filename).resolve()
                if not target.is_relative_to(scratch) or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise RuntimeError('The device-library archive contains an unsafe path.')
            package.extractall(scratch)
        source = next(scratch.rglob('IDevice.xcframework'))
        info = plistlib.loads((source / 'Info.plist').read_bytes())
        for item in info['AvailableLibraries']:
            folder = source / item['LibraryIdentifier']
            framework = folder / 'IDevice.framework'
            framework.mkdir()
            shutil.move(folder / item['LibraryPath'], framework / 'IDevice')
            archive = framework / 'IDevice'
            combined = folder / 'idevice-combined.o'
            platform = {'ios-arm64': 'ios', 'ios-arm64-simulator': 'ios-simulator',
                        'macos-arm64': 'macos', 'tvos-arm64': 'tvos',
                        'tvos-arm64-simulator': 'tvos-simulator'}[item['LibraryIdentifier']]
            minimum = '15.0' if platform == 'macos' else '26.0'
            sdk = 'macosx' if platform == 'macos' else ('appletvos' if platform.startswith('tvos') else 'iphoneos')
            version = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-version'], text=True).strip()
            subprocess.run(['xcrun', 'ld', '-r', '-arch', 'arm64', '-platform_version', platform, minimum, version,
                            '-all_load', str(archive), '-o', str(combined)], check=True)
            hidden = folder / 'rust-private-symbols.txt'
            hidden.write_text('_rust_eh_personality\n')
            subprocess.run(['xcrun', 'nmedit', '-R', str(hidden), str(combined)], check=True)
            archive.unlink()
            subprocess.run(['xcrun', 'libtool', '-static', '-o', str(archive), str(combined)], check=True)
            combined.unlink(); hidden.unlink()
            os.chmod(framework / 'IDevice', 0o755)
            shutil.move(folder / item['HeadersPath'], framework / 'Headers')
            modules = framework / 'Modules'
            modules.mkdir()
            old = framework / 'Headers/module.modulemap'
            contents = old.read_text()
            # Upstream lists idevice.h as an umbrella header. Framework modules
            # resolve it under Headers without exporting another global include/.
            contents = contents.replace('module IDevice', 'framework module IDevice')
            (modules / 'module.modulemap').write_text(contents)
            old.unlink()
            (framework / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'io.sidestore.idevice', 'CFBundleExecutable': 'IDevice',
                'CFBundleName': 'IDevice', 'CFBundlePackageType': 'FMWK',
                'CFBundleShortVersionString': '0.1.68', 'CFBundleVersion': '1',
            }))
            item['LibraryPath'] = 'IDevice.framework'
            item['BinaryPath'] = 'IDevice.framework/IDevice'
            item.pop('HeadersPath', None)
        (source / 'Info.plist').write_bytes(plistlib.dumps(info))
        (source / '.orbit-source-sha256').write_text(SHA256 + '\n')
        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        shutil.move(source, OUTPUT)
    print('Orbit refresh device library is ready.')

if __name__ == '__main__':
    main()
