#!/usr/bin/env python3
"""Expose the canonical app as Xcode's build product without copying it."""
import argparse
from pathlib import Path
import shutil
import uuid


def expose_product(product, canonical):
    product, canonical = Path(product), Path(canonical)
    # Xcode may have created empty wrapper directories before the script phase.
    # Never remove an installed app or follow an existing product symlink.
    parent = product.parent.resolve()
    if (product.name != 'OrbitMacInstall.app' or parent == canonical.parent.resolve()
            or parent.is_relative_to(canonical.resolve())):
        raise ValueError('The Xcode product must be separate from the installed Orbit Mac app.')
    if not (canonical / 'Contents/Info.plist').is_file() or not (canonical / 'Contents/MacOS/OrbitMacApp').is_file():
        raise ValueError('Install Orbit Mac successfully before exposing its Xcode product.')
    if product.exists() and not product.is_symlink():
        if any(path.is_symlink() or not path.is_dir() for path in product.rglob('*')):
            raise ValueError('The Xcode product contains files. Clean this build folder and try again.')
        shutil.rmtree(product)
    product.parent.mkdir(parents=True, exist_ok=True)
    temporary = product.with_name(product.name + '.' + uuid.uuid4().hex)
    try:
        temporary.symlink_to(canonical, target_is_directory=True)
        temporary.replace(product)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('product', type=Path)
    args = parser.parse_args()
    try:
        expose_product(args.product, Path.home() / 'Applications/Orbit Mac.app')
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + '\n')
