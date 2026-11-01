#!/usr/bin/env python3
"""Canonical, certificate-pinned Mac updates from committed detached source."""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

from local_identity import read_identity

HOME = Path.home()
REGISTRY = HOME / '.orbit' / 'mac-installation.json'
CANONICAL = HOME / 'Applications' / 'Orbit Mac.app'
ACTIVE = {'accepted', 'building', 'installing', 'restarting', 'installed'}


def run(args, cwd=None, capture=True, env=None):
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout.decode().strip() if capture else ''


def read(path, default=None):
    return json.loads(Path(path).read_text()) if Path(path).exists() else default


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(value, file, indent=2)
        file.flush(); os.fsync(file.fileno())
    os.replace(temporary, path)


def info(app):
    return plistlib.loads((Path(app) / 'Contents/Info.plist').read_bytes())


def certificate(app):
    # Pin the actual leaf certificate, not its display name or the team alone.
    with tempfile.TemporaryDirectory(prefix='orbit-certificate-') as folder:
        prefix = str(Path(folder) / 'cert')
        run(['/usr/bin/codesign', '-d', '--extract-certificates=' + prefix, app])
        return hashlib.sha1(Path(prefix + '0').read_bytes()).hexdigest().upper()


def requirement(app):
    result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(app)], capture_output=True, text=True, check=True)
    match = re.search(r'^designated => (.+)$', result.stderr + result.stdout, re.M)
    if not match:
        raise ValueError('Orbit’s existing signing requirement could not be read.')
    return match[1]


def identities():
    text = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
    available = re.findall(r'\b([A-Fa-f0-9]{40}) "([^"]+)"', text)
    public = run(['/usr/bin/security', 'find-certificate', '-a', '-p'])
    teams = {}
    for pem in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', public, re.S):
        der = base64.b64decode(''.join(pem.splitlines()[1:-1]))
        sha = hashlib.sha1(der).hexdigest().upper()
        if sha not in {value[0].upper() for value in available}: continue
        subject = subprocess.run(['/usr/bin/openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'], input=pem.encode(), capture_output=True, check=True).stdout.decode()
        match = re.search(r'(?:^|,)OU=([A-Z0-9]{10})(?:,|$)', subject)
        if match: teams[sha] = match[1]
    return [(sha, name, teams.get(sha.upper(), '')) for sha, name in available]


def choose_certificate(available, team, pinned=None, requested=None):
    matches = [(sha.upper(), name) for sha, name, cert_team in available
               if (not requested or requested.upper() == sha.upper() or requested == name)
               and (not pinned or sha.upper() == pinned.upper())
               and cert_team == team and (pinned or name.startswith('Apple Development: '))]
    if len(matches) != 1:
        raise ValueError('Unlock the original signing certificate in Keychain. Orbit will keep its existing certificate; it won’t switch identities.')
    return matches[0][0]


def running_apps(bundle_id):
    # Only stop applications with this exact bundle ID, never name-based pkill.
    result = []
    for line in run(['/bin/ps', '-axo', 'pid=,comm=']).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or '.app/Contents/MacOS/' not in parts[1]:
            continue
        app = Path(parts[1].split('.app/Contents/MacOS/')[0] + '.app')
        try:
            if info(app).get('CFBundleIdentifier') == bundle_id:
                result.append((int(parts[0]), app))
        except (OSError, ValueError):
            continue
    return result


def resolve_installation(source):
    identity = read_identity(source)
    bundle_id = identity['prefix'] + '.mac'
    previous = read(REGISTRY)
    override = os.environ.get('ORBIT_MAC_APP_PATH')
    if override and Path(override).expanduser() != CANONICAL:
        raise ValueError('Orbit Mac lives at ~/Applications/Orbit Mac.app. Remove ORBIT_MAC_APP_PATH to keep one installed copy.')
    existing = CANONICAL if CANONICAL.exists() else None
    copies = running_apps(bundle_id)
    if existing is None and copies:
        existing = copies[0][1]
    pinned = previous.get('certificate') if previous else None
    req = previous.get('requirement') if previous else None
    state_root = previous['stateRoot'] if previous else os.environ.get('ORBIT_HOME', str(HOME / '.orbit'))
    if previous and (previous['bundleID'] != bundle_id or previous['path'] != str(CANONICAL)):
        raise ValueError('Local signing settings differ from the installed Orbit. Restore its bundle ID before rebuilding.')
    if existing:
        if info(existing).get('CFBundleIdentifier') != bundle_id:
            raise ValueError('The canonical app has a different bundle ID. Restore its local signing settings.')
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', existing])
        found = certificate(existing)
        if pinned and found != pinned:
            raise ValueError('The installed Orbit certificate changed. Restore the original app before updating.')
        pinned = found
        req = req or requirement(existing)
        state_root = info(existing).get('OrbitStateRoot', state_root)
    if not Path(state_root).is_absolute():
        raise ValueError('Orbit’s state folder must be an absolute path.')
    selected = choose_certificate(identities(), identity['team'], pinned, os.environ.get('ORBIT_MAC_SIGNING_IDENTITY'))
    for _, app in copies:
        if certificate(app) != selected:
            raise ValueError('Another running Orbit has a different certificate. Close it before updating.')
    return dict(path=str(CANONICAL), bundleID=bundle_id, certificate=selected,
                requirement=req, sourceRoot=str(Path(run(['/usr/bin/git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=source)).parent), stateRoot=state_root)


def local_rpc(root, method, params=None):
    payload = json.dumps(dict(method=method, params=params or {})).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(5)
        stream.connect(str(Path(root) / 'control.sock'))
        stream.sendall(b'ORBT' + struct.pack('>I', len(payload)) + payload)
        def exact(count):
            data = bytearray()
            while len(data) < count:
                block = stream.recv(count - len(data))
                if not block: raise ValueError('Orbit closed its local reply.')
                data.extend(block)
            return data
        length, = struct.unpack('>I', exact(4))
        if not 0 < length <= 8 * 1024 * 1024: raise ValueError('Invalid Orbit reply size.')
        return json.loads(exact(length))


def lock():
    REGISTRY.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(REGISTRY.with_suffix('.lock'), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        raise ValueError('Orbit Mac is already updating. Check its progress before trying again.')
    return descriptor


def job_path(installation):
    return Path(installation['stateRoot']) / 'MacUpdate' / 'job.json'


def update_job(path, **fields):
    value = read(path, {})
    value.update(fields, updatedAt=time.time())
    write(path, value)
    return value


def stop_apps(bundle_id):
    for pid, _ in running_apps(bundle_id):
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 15
    while running_apps(bundle_id):
        if time.monotonic() > deadline:
            raise ValueError('Orbit is still closing. The installed app was left intact.')
        time.sleep(0.2)


def install(staged, installation):
    target = Path(installation['path'])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', staged])
    if info(staged)['CFBundleIdentifier'] != installation['bundleID'] or certificate(staged) != installation['certificate']:
        raise ValueError('The new build changed Orbit’s bundle ID or signing certificate. The installed app was left intact.')
    if installation['requirement']:
        run(['/usr/bin/codesign', '--verify', '--test-requirement', '=' + installation['requirement'], staged])
    # Validate everything, including the current installed app, before closing it.
    if target.exists():
        if certificate(target) != installation['certificate'] or info(target)['CFBundleIdentifier'] != installation['bundleID']:
            raise ValueError('The installed app changed during the build. Update stopped.')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.orbit-update-', dir=target.parent) as folder:
        prepared, backup = Path(folder) / target.name, Path(folder) / 'Previous.app'
        run(['/usr/bin/ditto', staged, prepared])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', prepared])
        stop_apps(installation['bundleID'])
        try:
            if target.exists():
                target.rename(backup)
            prepared.rename(target)
            run(['/usr/bin/codesign', '--verify', '--deep', '--strict', target])
        except BaseException:
            if backup.exists():
                if target.exists(): shutil.rmtree(target)
                backup.rename(target)
                subprocess.run(['/usr/bin/open', str(target)])
            raise
    installation['requirement'] = installation['requirement'] or requirement(target)
    write(REGISTRY, installation)


def checkout(source, revision, folder):
    run(['/usr/bin/git', 'worktree', 'add', '--detach', folder, revision], cwd=source)
    # User-owned configuration and generated native binaries stay out of Git.
    (folder / 'Config').mkdir(exist_ok=True)
    shutil.copy2(source / 'Config/Local.xcconfig', folder / 'Config/Local.xcconfig')
    for relative in ['Vendor/OrbitNet.xcframework', 'Vendor/DeviceGateway/IDevice.xcframework']:
        native = source / relative
        if native.exists():
            shutil.copytree(native, folder / relative, symlinks=True)


def select_xcode():
    candidates = []
    if os.environ.get('DEVELOPER_DIR'):
        candidates.append(Path(os.environ['DEVELOPER_DIR']))
    try: candidates.append(Path(run(['/usr/bin/xcode-select', '-p'])))
    except subprocess.CalledProcessError: pass
    for _, app in running_apps_for_xcode(): candidates.append(app / 'Contents/Developer')
    def version(app):
        try: return tuple(int(part) for part in info(app).get('CFBundleShortVersionString', '0').split('.'))
        except (ValueError, OSError): return (0,)
    candidates += [app / 'Contents/Developer' for app in sorted(Path('/Applications').glob('Xcode*.app'), key=version, reverse=True)]
    for candidate in candidates:
        if (candidate / 'Platforms/iPhoneOS.platform/Developer/SDKs').is_dir(): return str(candidate)
    raise ValueError('Open a full Xcode with the iPhone SDK installed, then rebuild Orbit Mac.')


def running_apps_for_xcode():
    copies = []
    for line in run(['/bin/ps', '-axo', 'pid=,comm=']).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].endswith('.app/Contents/MacOS/Xcode'):
            copies.append((int(parts[0]), Path(parts[1].split('.app/Contents/MacOS/')[0] + '.app')))
    return copies


def build(source, mode, installation=None, job=None):
    revision = run(['/usr/bin/git', 'rev-parse', 'HEAD^{commit}'], cwd=source)
    if installation and running_apps(installation['bundleID']):
        response = local_rpc(installation['stateRoot'], 'mac_update_prepare')
        if 'error' in response and not response['error'].startswith('Unknown Orbit method:'):
            raise ValueError(response['error'])
    if job:
        update_job(job, state='building', stage='Building committed source…', revision=revision, pid=os.getpid())
    with tempfile.TemporaryDirectory(prefix='orbit-mac-build-') as temporary:
        folder = Path(temporary) / 'Source'
        try:
            checkout(source, revision, folder)
            env = os.environ.copy()
            # No Xcode parent build settings may leak into the SwiftPM packager.
            env['PATH'] = '/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '/usr/bin:/bin')
            env['DEVELOPER_DIR'] = select_xcode()
            if installation:
                env.update(ORBIT_MAC_SIGNING_IDENTITY=installation['certificate'], ORBIT_CANONICAL_BUILD='1',
                           ORBIT_SOURCE_ROOT=installation['sourceRoot'], ORBIT_STATE_ROOT=installation['stateRoot'])
            # Stable, serialized build cache; never use the user's working build tree.
            cache = REGISTRY.parent / 'MacBuildCache'
            cache.mkdir(exist_ok=True, mode=0o700)
            (folder / '.build').symlink_to(cache, target_is_directory=True)
            run(['/bin/bash', folder / 'scripts/package_mac_app.sh', '--build-only'], cwd=folder, env=env, capture=False)
            staged = folder / 'dist/Orbit Mac.app'
            if mode == '--build-only':
                destination = source / 'dist/Orbit Mac.app'
                destination.parent.mkdir(exist_ok=True)
                if destination.exists(): shutil.rmtree(destination)
                run(['/usr/bin/ditto', staged, destination])
                print(destination)
                return
            update_job(job, state='installing', stage='Installing Orbit Mac…')
            install(staged, installation)
            update_job(job, state='installed', stage='Waiting for Orbit Mac to reopen…')
            if mode == '--install-only':
                return
            update_job(job, state='restarting', stage='Reconnecting to Orbit Mac…')
            run(['/usr/bin/open', installation['path']])
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                try:
                    status = local_rpc(installation['stateRoot'], 'mac_update_status').get('result', {})
                    if status.get('runningRevision') == revision and status.get('runningPath') == installation['path']:
                        update_job(job, state='succeeded', stage='Orbit Mac is up to date.')
                        return
                except (OSError, ValueError):
                    pass
                time.sleep(0.5)
            update_job(job, state='unknownCompletion', stage='Installed. Reopen Orbit Mac to confirm the update.')
            raise ValueError('The app was installed, but Orbit could not confirm it reopened. Reopen ~/Applications/Orbit Mac.app.')
        finally:
            if folder.exists():
                subprocess.run(['/usr/bin/git', 'worktree', 'remove', '--force', str(folder)], cwd=source, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', nargs='?', default='run', choices=['run', '--unused'])
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--install-only', action='store_true')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--start', action='store_true')
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--lock-fd', type=int)
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    source = (args.source or Path(__file__).resolve().parents[1]).resolve()
    descriptor = args.lock_fd if args.lock_fd is not None else lock()
    job = None
    try:
        if args.build_only:
            read_identity(source)
            build(source, '--build-only')
            return
        installation = resolve_installation(source)
        job = job_path(installation)
        if args.worker:
            # The accepting process already wrote the durable request and kept its lock.
            update_job(job, pid=os.getpid())
        else:
            log = job.parent / (str(uuid.uuid4()) + '.log')
            write(job, dict(id=log.stem, state='accepted', stage='Starting Mac update…', logPath=str(log), startedAt=time.time(), pid=os.getpid()))
            if args.start:
                log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                fd = os.open(log, os.O_CREAT | os.O_WRONLY, 0o600)
                with os.fdopen(fd, 'w') as output:
                    child = subprocess.Popen([sys.executable, __file__, '--worker', '--source', str(source), '--lock-fd', str(descriptor)],
                        stdin=subprocess.DEVNULL, stdout=output, stderr=output, start_new_session=True, pass_fds=(descriptor,))
                value = update_job(job, pid=child.pid)
                print(json.dumps(value))
                return
        build(source, '--install-only' if args.install_only else 'run', installation, job)
    except BaseException as error:
        if job and read(job, {}).get('state') != 'unknownCompletion':
            update_job(job, state='failed', stage='Update stopped. Your app and data are safe.', failure=str(error))
        raise
    finally:
        os.close(descriptor)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors='replace')[-6000:], file=sys.stderr)
        sys.exit(1)
