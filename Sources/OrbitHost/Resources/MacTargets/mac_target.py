#!/usr/bin/env python3
"""Local Mac app builds. Committed source, pinned identity, durable installation."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


def run(args, cwd=None):
    result = subprocess.run([str(a) for a in args], cwd=cwd, capture_output=True, check=True)
    return result.stdout.decode().strip()


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(value, file, indent=2)
        file.flush(); os.fsync(file.fileno())
    os.replace(temporary, path)


def read(path):
    return json.loads(Path(path).read_text())


def info(app):
    return plistlib.loads((Path(app) / 'Contents/Info.plist').read_bytes())


def signature(app):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    with tempfile.TemporaryDirectory(prefix='orbit-cert-') as folder:
        prefix = str(Path(folder) / 'cert')
        run(['/usr/bin/codesign', '-d', '--extract-certificates=' + prefix, app])
        cert = Path(prefix + '0')
        if not cert.exists():
            raise ValueError('Choose a certificate-signed installed app. Ad-hoc identities cannot be preserved across builds.')
        fingerprint = hashlib.sha1(cert.read_bytes()).hexdigest().upper()
    output = subprocess.run(['/usr/bin/codesign', '-dr-', str(app)], capture_output=True, text=True, check=True)
    match = re.search(r'^designated => (.+)$', output.stdout + output.stderr, re.M)
    if not match:
        raise ValueError('The app’s signing requirement could not be read.')
    return fingerprint, match[1]


def available_certificates():
    return re.findall(r'\b([A-Fa-f0-9]{40}) "([^"]+)"', run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning']))


def select_certificate(requested=None, pinned=None):
    matches = [sha.upper() for sha, name in available_certificates()
               if (not requested or requested == name or requested.upper() == sha.upper())
               and (not pinned or pinned == sha.upper())
               and (pinned or name.startswith('Apple Development: '))]
    if len(matches) != 1:
        raise ValueError('Select one available Apple Development certificate in Signing identity. Updates need the installed app’s original certificate in Keychain.')
    return matches[0]


def processes():
    values = []
    for line in run(['/bin/ps', '-axo', 'pid=,comm=']).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and '.app/Contents/MacOS/' in parts[1]:
            app = Path(parts[1].split('.app/Contents/MacOS/')[0] + '.app')
            try:
                values.append((int(parts[0]), app, info(app)))
            except (OSError, ValueError):
                pass
    return values


def bundle_id(value):
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', value or ''):
        raise ValueError('Set a reverse-DNS bundle ID for this Mac app.')
    return value


def safe_name(value):
    if not value or value in ('.', '..') or '/' in value or '\x00' in value:
        raise ValueError('Choose an app or product name without path separators.')
    return value


def xcode_settings(project, scheme, configuration):
    option = '-workspace' if project.suffix == '.xcworkspace' else '-project'
    arguments = [option, str(project), '-scheme', scheme, '-configuration', configuration, '-destination', 'platform=macOS']
    rows = json.loads(run(['/usr/bin/xcodebuild', *arguments, '-showBuildSettings', '-json'], cwd=project.parent))
    apps = [r['buildSettings'] for r in rows if r.get('buildSettings', {}).get('WRAPPER_EXTENSION') == 'app'
            and r['buildSettings'].get('PLATFORM_NAME') == 'macosx']
    if len(apps) != 1:
        raise ValueError('Choose a scheme with one runnable native Mac app.')
    return arguments, apps[0]


def inspect(params):
    project = Path(params['project']).expanduser().resolve()
    if project.name == 'Package.swift':
        project = project.parent
    scheme = safe_name(params['scheme'])
    if not Path(params['project']).is_absolute() or not project.exists():
        raise ValueError('Choose an existing absolute project or Swift package path.')
    if project.name == 'Orbit.xcodeproj' or (project / 'Sources/OrbitMacApp').exists():
        raise ValueError('Use Rebuild Orbit Mac for Orbit itself. It preserves Orbit’s local configuration and running jobs.')
    repository = Path(run(['/usr/bin/git', 'rev-parse', '--show-toplevel'], cwd=project if project.is_dir() and project.suffix not in ('.xcodeproj', '.xcworkspace') else project.parent)).resolve()
    relative = str(project.relative_to(repository))
    branch = params.get('branch') or run(['/usr/bin/git', 'branch', '--show-current'], cwd=repository) or 'main'
    run(['/usr/bin/git', 'rev-parse', '--verify', '--end-of-options', branch + '^{commit}'], cwd=repository)
    configuration = params.get('configuration', 'Debug')
    if configuration not in ('Debug', 'Release'):
        raise ValueError('Choose Debug or Release.')
    defaults = {}
    if project.suffix in ('.xcodeproj', '.xcworkspace'):
        kind = 'xcode'
        _, settings = xcode_settings(project, scheme, configuration)
        defaults = dict(CFBundleIdentifier=settings.get('PRODUCT_BUNDLE_IDENTIFIER', ''),
                        CFBundleName=settings.get('PRODUCT_NAME', scheme), CFBundleExecutable=settings.get('EXECUTABLE_NAME', scheme))
    elif (project / 'Package.swift').is_file():
        kind = 'swiftpm'
        package = json.loads(run(['/usr/bin/swift', 'package', '--package-path', project, 'dump-package']))
        if not any(p['name'] == scheme and 'executable' in p['type'] for p in package['products']):
            raise ValueError('Choose an executable Swift package product.')
        defaults = dict(CFBundleName=scheme, CFBundleExecutable=scheme)
    else:
        raise ValueError('Choose an Xcode project, workspace or Swift package.')
    wanted = params.get('bundleID') or defaults.get('CFBundleIdentifier')
    matches = [(app, meta) for _, app, meta in processes()
               if (meta.get('CFBundleIdentifier') == wanted if wanted else meta.get('CFBundleExecutable') == scheme)]
    paths = {str(app) for app, _ in matches}
    if len(paths) > 1:
        raise ValueError('Several matching copies are running. Close extras before registering this app.')
    explicit = params.get('installPath')
    if explicit:
        destination = Path(explicit).expanduser()
        if not destination.is_absolute() or destination.suffix != '.app' or destination.is_symlink():
            raise ValueError('Choose an absolute .app installation path without a symlink.')
        destination = destination.resolve()
        if matches and destination != matches[0][0].resolve():
            raise ValueError('Use the running app’s current path to preserve its identity and permissions.')
    elif matches:
        destination = matches[0][0]
    else:
        installed = []
        if wanted:
            for folder in (Path.home() / 'Applications', Path('/Applications')):
                for app in folder.glob('*.app'):
                    try:
                        if info(app).get('CFBundleIdentifier') == wanted:
                            installed.append(app)
                    except (OSError, ValueError):
                        pass
        if len(installed) > 1:
            raise ValueError('Several installed copies match. Set the installation path.')
        destination = installed[0] if installed else Path.home() / 'Applications' / (safe_name(defaults['CFBundleName']) + '.app')
    previous = info(destination) if destination.exists() else None
    wanted = bundle_id(params.get('bundleID') or (previous or defaults).get('CFBundleIdentifier'))
    if previous and previous.get('CFBundleIdentifier') != wanted:
        raise ValueError('Keep the installed app’s bundle ID to preserve its data and pairing.')
    pinned, requirement = signature(destination) if previous else (None, None)
    selected = select_certificate(params.get('signingIdentity'), pinned)
    if kind == 'swiftpm':
        if params.get('infoPlist'):
            plist_path = Path(params['infoPlist']).resolve()
            defaults = plistlib.loads(plist_path.read_bytes())
        defaults = previous or defaults
        defaults.update(CFBundleIdentifier=wanted, CFBundlePackageType='APPL', CFBundleExecutable=scheme)
        defaults.setdefault('NSPrincipalClass', 'NSApplication')
        defaults.setdefault('LSMinimumSystemVersion', '15.0')
    return dict(project=str(project), sourceRoot=str(repository), relativeProject=relative, scheme=scheme,
                kind=kind, branch=branch, configuration=configuration, installPath=str(destination), bundleID=wanted,
                certificate=selected, requirement=requirement, infoPlist=defaults, teamID=params.get('teamID', ''))


def verify(app, config):
    if info(app).get('CFBundleIdentifier') != config['bundleID']:
        raise ValueError('The app bundle ID changed. The installed app was left intact.')
    cert, _ = signature(app)
    if cert != config['certificate']:
        raise ValueError('The signing certificate changed. The installed app was left intact.')
    if config.get('requirement'):
        run(['/usr/bin/codesign', '--verify', '--test-requirement', '=' + config['requirement'], app])


def digest(app):
    binary = Path(app) / 'Contents/MacOS' / safe_name(info(app)['CFBundleExecutable'])
    return hashlib.sha256(binary.read_bytes()).hexdigest()


def stop(config):
    target = Path(config['installPath']).resolve()
    matching = [(pid, app) for pid, app, meta in processes() if meta.get('CFBundleIdentifier') == config['bundleID']]
    if any(app.resolve() != target for _, app in matching):
        raise ValueError('Another copy of this app is running. Close it before updating.')
    for pid, _ in matching:
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 15
    while any(app.resolve() == target for _, app, _ in processes()):
        if time.monotonic() > deadline:
            raise ValueError('The app is still closing. Finish its current work, then build again.')
        time.sleep(0.2)


def update(job, **fields):
    value = read(job); value.update(fields, updatedAt=time.time()); write(job, value)
    return value


def install(staged, config, job, launch):
    target = Path(config['installPath'])
    verify(staged, config)
    if target.exists():
        verify(target, config)
    elif config.get('requirement'):
        raise ValueError('The registered installed app is missing. Restore it before updating.')
    target.parent.mkdir(parents=True, exist_ok=True)
    transaction = target.parent / ('.orbit-install-' + read(job)['id'])
    transaction.mkdir(mode=0o700)
    prepared, backup = transaction / 'Next.app', transaction / 'Previous.app'
    run(['/usr/bin/ditto', staged, prepared])
    verify(prepared, config)
    fingerprint = digest(prepared)
    previous_digest = digest(target) if target.exists() else None
    previous_running = any(app.resolve() == target.resolve() for _, app, _ in processes())
    update(job, stage='Installing on this Mac…', phase='installing', transaction=str(transaction), executableDigest=fingerprint,
           previousDigest=previous_digest, previousRunning=previous_running)
    replaced = False
    try:
        stop(config)
        if target.exists():
            target.rename(backup)
        prepared.rename(target); replaced = True
        verify(target, config)
        if digest(target) != fingerprint:
            raise ValueError('Installed app readback did not match the build.')
        if launch:
            update(job, stage='Opening the app…', phase='launching')
            run(['/usr/bin/open', '-n', target])
            deadline = time.monotonic() + 20
            while not any(app.resolve() == target.resolve() for _, app, _ in processes()):
                if time.monotonic() > deadline:
                    raise ValueError('The new app did not stay open. The previous app was restored.')
                time.sleep(0.25)
            time.sleep(2)
            if not any(app.resolve() == target.resolve() for _, app, _ in processes()):
                raise ValueError('The new app quit after launch. The previous app was restored.')
        update(job, state='succeeded', stage='Built and opened on this Mac.' if launch else 'Installed on this Mac.', installedPath=str(target), launched=launch)
    except BaseException:
        # Preserve the old signed bundle until both installation and launch pass.
        if replaced:
            stop(config)
            shutil.rmtree(target)
        if backup.exists():
            backup.rename(target)
            subprocess.run(['/usr/bin/open', target])
        raise
    finally:
        if not backup.exists() or read(job).get('state') == 'succeeded':
            shutil.rmtree(transaction, ignore_errors=True)


def build(config, job, launch):
    repository = Path(config['sourceRoot'])
    revision = run(['/usr/bin/git', 'rev-parse', '--verify', '--end-of-options', config['branch'] + '^{commit}'], cwd=repository)
    directory = Path(job).parent / 'Source'
    update(job, state='running', phase='building', stage='Building committed source…', revision=revision, pid=os.getpid())
    try:
        run(['/usr/bin/git', 'worktree', 'add', '--detach', directory, revision], cwd=repository)
        project = directory / config['relativeProject']
        cache = Path(job).parents[2] / 'MacTargetCache' / hashlib.sha256((str(repository) + config['relativeProject'] + config['scheme']).encode()).hexdigest()[:20]
        cache.mkdir(parents=True, exist_ok=True, mode=0o700)
        staged = Path(job).parent / 'Built.app'
        if config['kind'] == 'xcode':
            arguments, settings = xcode_settings(project, config['scheme'], config['configuration'])
            subprocess.run(['/usr/bin/xcodebuild', *arguments, '-derivedDataPath', cache, 'build',
                            'PRODUCT_BUNDLE_IDENTIFIER=' + config['bundleID'], 'CODE_SIGN_IDENTITY=' + config['certificate'],
                            *(['DEVELOPMENT_TEAM=' + config['teamID']] if config.get('teamID') else [])], check=True)
            # Query with the same derived-data path used for compilation.
            rows = json.loads(run(['/usr/bin/xcodebuild', *arguments, '-derivedDataPath', cache, '-showBuildSettings', '-json']))
            settings = next(r['buildSettings'] for r in rows if r.get('buildSettings', {}).get('WRAPPER_EXTENSION') == 'app')
            run(['/usr/bin/ditto', Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME'], staged])
        else:
            arguments = ['--package-path', str(project), '--scratch-path', str(cache), '-c', config['configuration'].lower()]
            subprocess.run(['/usr/bin/swift', 'build', *arguments, '--product', config['scheme']], check=True)
            products = Path(run(['/usr/bin/swift', 'build', *arguments, '--show-bin-path']))
            (staged / 'Contents/MacOS').mkdir(parents=True)
            (staged / 'Contents/Resources').mkdir()
            shutil.copy2(products / config['scheme'], staged / 'Contents/MacOS' / config['scheme'])
            for resource in products.glob('*.bundle'):
                shutil.copytree(resource, staged / 'Contents/Resources' / resource.name, symlinks=True)
            metadata = dict(config['infoPlist']); metadata['OrbitBuildRevision'] = revision
            (staged / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
            signing = []
            target = Path(config['installPath'])
            if target.exists():
                entitlements = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', target], capture_output=True, check=True).stdout
                if entitlements.strip():
                    plistlib.loads(entitlements)
                    entitlement_file = Path(job).parent / 'Entitlements.plist'
                    entitlement_file.write_bytes(entitlements)
                    signing = ['--entitlements', str(entitlement_file)]
            run(['/usr/bin/codesign', '--force', '--sign', config['certificate'], '--timestamp=none', *signing, staged])
        install(staged, config, job, launch)
    finally:
        if directory.exists():
            subprocess.run(['/usr/bin/git', 'worktree', 'remove', '--force', directory], cwd=repository, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def worker_alive(pid, job):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A recycled PID must never authorize signalling another process group.
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True)
    return result.returncode == 0 and result.stdout.strip().endswith('mac_target.py worker ' + str(job))


def status(job):
    value = read(job)
    if value['state'] == 'running' and not value.get('pid') and time.time() - value.get('createdAt', time.time()) > 30:
        value = update(job, state='failed', failureMessage='The Mac build did not start. Try again.')
    if value['state'] in ('running', 'unknownCompletion') and value.get('pid'):
        if not worker_alive(value['pid'], job):
            if value.get('phase') in ('installing', 'launching'):
                # A killed worker is not proof of completion. Keep recovery material.
                config = read(Path(job).parent / 'config.json')
                target = Path(config['installPath'])
                try:
                    verify(target, config)
                    if digest(target) != value.get('executableDigest'):
                        raise ValueError('Installed revision differs.')
                    if value.get('launch') and not any(app.resolve() == target.resolve() for _, app, _ in processes()):
                        raise ValueError('App launch was not confirmed.')
                    value = update(job, state='succeeded', stage='Installation verified after interruption.', installedPath=str(target), launched=value.get('launch', False))
                except (OSError, ValueError, subprocess.CalledProcessError):
                    # A crash between the two renames can leave only the rollback bundle.
                    transaction = Path(value.get('transaction', str(Path(job).parent / 'NoTransaction')))
                    backup = transaction / 'Previous.app'
                    restored = False
                    if target.exists() and value.get('previousDigest'):
                        try:
                            verify(target, config)
                            restored = digest(target) == value['previousDigest']
                            if restored and value.get('previousRunning') and not any(app.resolve() == target.resolve() for _, app, _ in processes()):
                                subprocess.run(['/usr/bin/open', str(target)])
                        except (OSError, ValueError, subprocess.CalledProcessError):
                            pass
                    if not target.exists() and backup.exists() and value.get('previousDigest'):
                        try:
                            verify(backup, config)
                            if digest(backup) == value['previousDigest']:
                                backup.rename(target)
                                restored = True
                                if value.get('previousRunning'):
                                    subprocess.run(['/usr/bin/open', str(target)])
                        except (OSError, ValueError, subprocess.CalledProcessError):
                            pass
                    if restored:
                        value = update(job, state='failed', stage='The previous app was restored.', failureMessage='Installation was interrupted. The previous app was restored; try building again.')
                    else:
                        value = update(job, state='unknownCompletion', stage='The update was interrupted. Check the installed app before rebuilding.', failureMessage='Installation could not be confirmed. Recovery files were retained.')
            else:
                value = update(job, state='failed', failureMessage='The Mac build was interrupted. Try again.')
    log = Path(job).parent / 'build.log'
    if log.exists():
        with log.open('rb') as file:
            file.seek(max(0, log.stat().st_size - 16000))
            value['log'] = file.read().decode(errors='replace')
    return value


def cancel(job):
    value = status(job)
    if value['state'] != 'running':
        return value
    if value.get('phase') in ('installing', 'launching'):
        raise ValueError('The app is being replaced. Wait for installation to finish before cancelling.')
    os.killpg(value['pid'], signal.SIGTERM)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['inspect', 'start', 'worker', 'status', 'cancel'])
    parser.add_argument('path', type=Path)
    parser.add_argument('--launch', action='store_true')
    args = parser.parse_args()
    if args.command == 'inspect':
        print(json.dumps(inspect(read(args.path)))); return
    if args.command == 'status':
        print(json.dumps(status(args.path))); return
    if args.command == 'cancel':
        print(json.dumps(cancel(args.path))); return
    if args.command == 'start':
        job = args.path
        value = read(job)
        with (job.parent / 'build.log').open('ab') as output:
            os.chmod(output.name, 0o600)
            process = subprocess.Popen([sys.executable, __file__, 'worker', str(job)], stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=output, start_new_session=True)
        # Only the worker changes phases after dispatch.
        print(json.dumps(update(job, pid=process.pid))); return
    job = args.path
    # The accepting parent durably records the PID before this worker changes phases.
    deadline = time.monotonic() + 10
    while read(job).get('pid') != os.getpid():
        if time.monotonic() > deadline:
            update(job, state='failed', failureMessage='Worker dispatch was interrupted. Try again.')
            return
        time.sleep(0.05)
    config = read(job.parent / 'config.json')
    descriptor = None
    try:
        def interrupted(_signal, _frame):
            raise InterruptedError('Build cancelled.')
        signal.signal(signal.SIGTERM, interrupted)
        # Serialize all registered Mac apps, including duplicate destinations.
        lock_path = job.parents[2] / 'mac-target.lock'
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        update(job, pid=os.getpid(), stage='Waiting for other Mac builds…')
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        build(config, job, read(job).get('launch', True))
    except BaseException as error:
        if isinstance(error, subprocess.CalledProcessError):
            print((error.stderr or b'').decode(errors='replace') if isinstance(error.stderr, bytes) else (error.stderr or ''), flush=True)
        update(job, state='cancelled' if isinstance(error, InterruptedError) else 'failed', failureMessage=str(error), stage='Build cancelled.' if isinstance(error, InterruptedError) else 'Mac build failed.')
    finally:
        if descriptor is not None:
            os.close(descriptor)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
