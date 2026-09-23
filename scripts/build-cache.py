#!/usr/bin/env python3
"""Report or clear this checkout's disposable Zig compilation cache."""
import argparse
import math
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
GIB = 1024 ** 3


def cache_bytes(cache):
    if cache.is_symlink():
        raise ValueError(f'Refusing a symlink cache: {cache}')
    if not cache.exists():
        return 0
    if not cache.is_dir():
        raise ValueError(f'Expected a cache directory: {cache}')
    # du measures allocated disk space, including hard-link deduplication.
    output = subprocess.check_output(['du', '-sk', str(cache)], text=True)
    return int(output.split()[0]) * 1024


def active_builds():
    # Be conservative across checkouts. In particular, `zig build` may launch
    # macos/build.nu while its own cache files are still in use.
    output = subprocess.check_output(['ps', '-axo', 'comm='], text=True,
                                     stderr=subprocess.PIPE)
    names = {Path(line.strip()).name for line in output.splitlines()}
    return names & {'zig', 'build', 'cghostty-test', 'xcodebuild', 'swift-frontend'}


def maintain(root, *, trim=False, clear=False, max_bytes=8 * GIB):
    cache = root / '.zig-cache'
    before = cache_bytes(cache)
    print(f'Zig compilation cache: {before / GIB:.2f} GiB ({cache})', flush=True)
    if not (clear or (trim and before > max_bytes)) or before == 0:
        return False

    tracked = subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '-z', '--', '.zig-cache'])
    if tracked:
        raise ValueError('Refusing to remove tracked files from .zig-cache')
    try:
        busy = active_builds()
    except (OSError, subprocess.CalledProcessError):
        print('Skipped cleanup: unable to check active builds. Run again outside the execution sandbox.')
        return False
    if busy:
        print(f'Skipped cleanup: build processes are active ({", ".join(sorted(busy))}).')
        return False

    # Do not touch downloads (zig-pkg), installed output (zig-out), Xcode
    # apps/results, release artifacts, source files or the global Zig cache.
    if cache.is_symlink():
        raise ValueError(f'Refusing a symlink cache: {cache}')
    shutil.rmtree(cache)
    print(f'Cleared {before / GIB:.2f} GiB. The next core build will recompile.', flush=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--trim', action='store_true', help='clear only above the size threshold')
    modes.add_argument('--clear', action='store_true', help='clear regardless of size')
    parser.add_argument('--max-gib', type=float, default=8,
                        help='threshold for --trim (default: 8 GiB); not a live quota')
    args = parser.parse_args()
    if not math.isfinite(args.max_gib) or args.max_gib <= 0:
        parser.error('--max-gib must be positive and finite')
    try:
        maintain(ROOT, trim=args.trim, clear=args.clear, max_bytes=args.max_gib * GIB)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Cache maintenance failed: {error}\n')


if __name__ == '__main__':
    main()
