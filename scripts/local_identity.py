#!/usr/bin/env python3
"""Read Orbit's ignored local signing identity without executing xcconfig code."""
import argparse
import re
from pathlib import Path


def read_identity(root):
    file = Path(root) / 'Config/Local.xcconfig'
    if not file.is_file():
        raise ValueError('Set Orbit’s identity in Config/Local.xcconfig before building.')
    values = {}
    for line in file.read_text().splitlines():
        parts = line.split('//', 1)[0].split('=', 1)
        if len(parts) == 2:
            values[parts[0].strip()] = parts[1].strip()
    prefix = values.get('ORBIT_BUNDLE_PREFIX', '')
    team = values.get('DEVELOPMENT_TEAM', '')
    phone = values.get('ORBIT_IOS_BUNDLE_IDENTIFIER', prefix + '.ios')
    def valid_id(value):
        return re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', value) and not value.startswith(('org.example.', 'com.yourname.'))
    if not valid_id(prefix) or not valid_id(phone) or not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Replace the sample bundle prefix and development team in Config/Local.xcconfig before building Orbit.')
    return {'prefix': prefix, 'team': team, 'phone': phone}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--field', choices=['prefix', 'team', 'phone'])
    args = parser.parse_args()
    try:
        identity = read_identity(Path(__file__).resolve().parents[1])
    except ValueError as error:
        parser.exit(1, str(error) + '\n')
    if args.field:
        print(identity[args.field])
