#!/usr/bin/env python3
"""Record and validate the installed core before a native-only build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def input_digest():
    digest = hashlib.sha256()
    # Local source inputs, including uncommitted additions/deletions. Downloaded
    # packages are immutable content-addressed inputs pinned by these manifests.
    paths = [ROOT / 'build.zig', ROOT / 'build.zig.zon', ROOT / 'scripts/zig-toolchain.json', ROOT / 'scripts/core-build-record.py']
    for directory in ('src', 'pkg', 'include'):
        for parent, dirs, files in os.walk(ROOT / directory):
            dirs[:] = sorted(d for d in dirs if d not in {'.zig-cache', 'zig-out', 'zig-pkg', '__pycache__', '.git'})
            paths.extend(Path(parent) / name for name in sorted(files) if name not in {'.DS_Store', 'README.md', 'AGENTS.md'})
    for path in sorted(paths):
        digest.update(str(path.relative_to(ROOT)).encode() + b'\0')
        digest.update(digest_file(path).encode() + b'\0')
    return digest.hexdigest()


def environment():
    return {name: subprocess.check_output(command, text=True).strip() for name, command in (
        ('zig', ['zig', 'version']),
        ('sdk', ['xcrun', '--show-sdk-build-version']),
    )}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['record', 'check'])
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--optimize', required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    archive = args.archive.resolve()
    record = archive.with_suffix('.build.json')
    try:
        expected = dict(schema=1, optimize=args.optimize, version=args.version,
                        inputs=input_digest(), archive=digest_file(archive), **environment())
        if args.mode == 'record':
            temporary = record.with_suffix('.tmp')
            temporary.write_text(json.dumps(expected, indent=2) + '\n')
            temporary.replace(record)
        else:
            actual = json.loads(record.read_text())
            mismatches = [key for key, value in expected.items() if actual.get(key) != value]
            if mismatches:
                raise ValueError('mismatched ' + ', '.join(mismatches))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Core reuse rejected: {error}. Build without --skip-core.\n')
    print(f'PASS: core {args.optimize}, {args.version}, source inputs and archive')


if __name__ == '__main__':
    main()
