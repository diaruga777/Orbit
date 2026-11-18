#!/usr/bin/env python3
"""Install/remove the current user's Orbit Mac launch agent; never root."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--app',type=Path,default=Path.home()/'Applications/Orbit Mac.app')
p.add_argument('--remove',action='store_true')
a=p.parse_args()
label='org.orbit.mac.agent'; domain=f'gui/{os.getuid()}'
plist=Path.home()/'Library/LaunchAgents'/f'{label}.plist'
if a.remove:
 subprocess.run(['launchctl','bootout',domain,str(plist)],check=False)
 plist.unlink(missing_ok=True)
else:
 executable=a.app.expanduser().resolve()/'Contents/MacOS/OrbitMacApp'
 if not executable.is_file(): p.error('Build and install Orbit Mac first')
 subprocess.run(['launchctl','bootout',domain,str(plist)],check=False,stderr=subprocess.DEVNULL)
 plist.parent.mkdir(parents=True,exist_ok=True)
 # Launch Services reuses a copy already running in this login session.
 # -W holds the job until exit. The next interval also covers a crash or update.
 args = ['/usr/bin/caffeinate', '-s', '/usr/bin/open', '-gjW']
 if 'ORBIT_HOME' in os.environ:
  args.extend(['--env', 'ORBIT_HOME=' + os.environ['ORBIT_HOME']])
 args.append(str(executable.parents[2]))
 config = {'Label': label, 'ProgramArguments': args, 'RunAtLoad': True,
           'StartInterval': 30, 'LimitLoadToSessionType': 'Aqua'}
 plist.write_bytes(plistlib.dumps(config)); plist.chmod(0o600)
 subprocess.run(['launchctl','bootstrap',domain,str(plist)],check=True)
 print(f'Orbit will start at login. Schedules run while you are logged in and the Mac is awake. {plist}')
