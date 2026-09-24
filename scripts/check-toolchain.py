#!/usr/bin/env python3
"""Fail before a build if the pinned Zig executable or its library is incomplete."""
import ast
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def check():
    expected = json.loads((ROOT / 'scripts/zig-toolchain.json').read_text())['version']
    executable = shutil.which('zig')
    remedy = 'Run bash scripts/install-zig.sh and add the returned directory to PATH.'
    if executable is None:
        raise ValueError(f'Zig {expected} is not on PATH. {remedy}')
    version = subprocess.check_output([executable, 'version'], text=True).strip()
    if version != expected:
        raise ValueError(f'Expected Zig {expected}, found {version} at {executable}. {remedy}')
    # zig env honors ZIG_LIB_DIR, unlike assuming lib/ next to the executable.
    result = subprocess.run([executable, 'env'], text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f'Incomplete Zig installation at {executable}: {result.stderr.strip()}. {remedy}')
    # Zig 0.16 emits Zig object notation; read only the library path without
    # evaluating the environment output.
    match = re.search(r'\.lib_dir\s*=\s*("(?:[^"\\]|\\.)*")', result.stdout)
    if match is None:
        # Also support JSON output from packaged distributions.
        try:
            library = json.loads(result.stdout)['lib_dir']
        except (ValueError, KeyError) as error:
            raise ValueError(f'Cannot read Zig library location. {remedy}') from error
    else:
        # Zig prints non-ASCII UTF-8 bytes as \xNN, which JSON strings cannot
        # decode. Parse only the quoted byte literal, never the ZON object.
        try:
            library = ast.literal_eval('b' + match.group(1)).decode('utf-8')
        except (SyntaxError, ValueError, UnicodeError) as error:
            raise ValueError(f'Cannot read Zig library location. {remedy}') from error
    for relative in ('std/std.zig', 'compiler/build_runner.zig'):
        if not (Path(library) / relative).is_file():
            raise ValueError(f'Incomplete Zig installation: missing {Path(library) / relative}. {remedy}')


if __name__ == '__main__':
    try:
        check()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Toolchain check failed: {error}')
