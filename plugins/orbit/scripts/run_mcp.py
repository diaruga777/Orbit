#!/usr/bin/env python3
"""Locate the user's Orbit checkout; plugin caches never become app state."""
import json
import os
from pathlib import Path
import sys

root = Path(os.environ.get('ORBIT_HOME', str(Path.home()/'.orbit')))
checkout = os.environ.get('ORBIT_CHECKOUT')
if not checkout:
    try:
        checkout = json.loads((root/'installation.json').read_text())['checkout']
    except (OSError, ValueError, KeyError):
        print('Run the Orbit setup skill, clone Orbit, and run scripts/bootstrap.sh first.', file=sys.stderr)
        sys.exit(1)
cli = Path(checkout).expanduser().resolve()/'bin/orbit'
if not cli.is_file():
    print('Orbit checkout moved. Run scripts/bootstrap.sh in its new location.', file=sys.stderr)
    sys.exit(1)
os.execv(sys.executable, [sys.executable, str(cli), 'mcp'])
