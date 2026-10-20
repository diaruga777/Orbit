#!/usr/bin/env python3
"""Build a host-specific Orbit plugin directory without ambiguous manifests."""
import argparse
from pathlib import Path
import shutil


def package(host, destination):
    source = Path(__file__).resolve().parents[1] / 'plugins/orbit'
    destination = Path(destination).expanduser().resolve()
    if destination.exists():
        raise ValueError('Destination already exists; choose a new directory or remove the old test package yourself.')
    if source == destination or source in destination.parents:
        raise ValueError('Choose an output directory outside the source plugin.')
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    # Cursor's portable MCP parser does not expand PLUGIN_ROOT. Select its
    # native manifest explicitly; other hosts get their own unambiguous shape.
    keep = {'codex':'.codex-plugin','cursor':'.cursor-plugin','claude':'.claude-plugin'}[host]
    for directory in ['.codex-plugin','.cursor-plugin','.claude-plugin']:
        if directory != keep:
            shutil.rmtree(destination / directory)
    if host != 'codex':
        (destination / 'plugin.json').unlink()
        (destination / 'mcp.json').unlink()
    if host != 'cursor':
        (destination / 'cursor.mcp.json').unlink()
    elif (destination / '.mcp.json').exists():
        (destination / '.mcp.json').unlink()
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host', choices=['codex','cursor','claude'])
    parser.add_argument('destination',type=Path)
    args = parser.parse_args()
    try:
        print(package(args.host, args.destination))
    except (OSError, ValueError) as error:
        parser.exit(1, 'Orbit: '+str(error)+'\n')

if __name__ == '__main__':
    main()
