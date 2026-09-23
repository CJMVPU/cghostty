#!/usr/bin/env python3
"""Run core builds, core tests, or native builds with shared cache maintenance."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_cache', ROOT / 'scripts/build-cache.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


def run(mode, arguments):
    if mode == 'native':
        command = ['nu', str(ROOT / 'macos/build.nu'), *arguments]
    else:
        command = ['zig', 'build']
        if mode == 'test':
            command.append('test')
        command.extend(['-Demit-macos-app=false', *arguments])
    with cache.build_lock(ROOT):
        # Cleaning Xcode output should not trigger a separate Zig cache trim.
        if not (mode == 'native' and '--action' in arguments and
                arguments[arguments.index('--action') + 1:][:1] == ['clean']):
            cache.maintain_locked(ROOT, trim=True)
        env = os.environ.copy()
        env['CGHOSTTY_BUILD_LOCK_ROOT'] = str(ROOT)
        return subprocess.run(command, cwd=ROOT, env=env).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['core', 'test', 'native'])
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        return run(args.mode, args.arguments)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Build failed: {error}\n')


if __name__ == '__main__':
    raise SystemExit(main())
