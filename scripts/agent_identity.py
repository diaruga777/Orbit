#!/usr/bin/env python3
"""Prepare a first-install identity or reuse the user's original local config."""
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

import mac_build as mac


def choose(rows):
    if len(rows) == 1:
        return rows[0]
    labels = [f'{name} · {team} · {sha}' for sha, name, team in rows]
    result = mac.run(['/usr/bin/osascript', '-e', '''on run choices
        set picked to choose from list choices with title "Orbit Setup" with prompt "Choose the signing certificate for Orbit."
        if picked is false then error number -128
        return item 1 of picked
    end run''', *labels])
    return rows[labels.index(result)]


def prepare(source):
    config = source / 'Config/Local.xcconfig'
    existing = mac.read_identity(source) if os.path.lexists(config) else None
    registry = mac.read(mac.REGISTRY, {})
    root = Path(registry.get('stateRoot', os.environ.get('ORBIT_HOME', str(Path.home() / '.orbit'))))
    if not root.is_absolute():
        raise ValueError('Orbit’s state folder must be an absolute path.')
    if not existing and (mac.CANONICAL.exists() or registry or (root / 'setup.json').exists()
                         or mac.read(root / 'config.json', {}).get('phoneBundleID')):
        raise ValueError('An Orbit installation already exists. Use its original checkout and Config/Local.xcconfig.')
    pinned = registry.get('certificate')
    if mac.CANONICAL.exists() and not pinned:
        pinned = mac.certificate(mac.CANONICAL)
    team = existing['team'] if existing else None
    requested = os.environ.get('ORBIT_MAC_SIGNING_IDENTITY')
    while True:
        rows = [(sha, name, cert_team) for sha, name, cert_team in mac.identities()
                if re.fullmatch('[A-Z0-9]{10}', cert_team) and (pinned or name.startswith('Apple Development: '))
                and (not team or team == cert_team) and (not pinned or pinned.upper() == sha.upper())
                and (not requested or requested == name or requested.upper() == sha.upper())]
        if rows:
            break
        subprocess.run(['/usr/bin/open', str(Path(os.environ['DEVELOPER_DIR']).parents[1])], check=True)
        message = ('Unlock or restore the original signing certificate in Keychain.' if pinned or requested else
                   'In Xcode Settings → Accounts, sign in and use Manage Certificates to create an Apple Development certificate.')
        mac.run(['/usr/bin/osascript', '-e', '''on run argv
            display dialog (item 1 of argv) buttons {"Cancel", "Check Again"} default button "Check Again" with title "Orbit Setup"
        end run''', message])
    sha, _, team = choose(rows)
    if not existing:
        prefix = 'dev.orbit.u' + uuid.uuid4().hex
        # Exclusive creation prevents a retry or a second installer replacing an identity.
        with os.fdopen(os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as output:
            output.write(f'ORBIT_BUNDLE_PREFIX = {prefix}\nDEVELOPMENT_TEAM = {team}\n')
    mac.read_identity(source)
    return sha


if __name__ == '__main__':
    try:
        print(prepare(Path(__file__).resolve().parents[1]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
