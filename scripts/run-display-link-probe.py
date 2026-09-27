#!/usr/bin/env python3
"""Build and launch a temporary foreground AppKit probe, separate from XCTest."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-directory', type=Path, required=True)
parser.add_argument('--repeat', type=int, default=1)
parser.add_argument('--matrix', action='store_true')
args = parser.parse_args()
if args.repeat < 1:
    parser.error('--repeat must be positive')
args.output_directory.mkdir(parents=True, exist_ok=True)
cases = [('metal', 'opaque', 'plain', '3', '1'), ('view', 'opaque', 'plain', '3', '1')]
if args.matrix:
    cases += [('metal', 'transparent', 'plain', '3', '1'),
              ('metal', 'transparent', 'glass', '3', '1'),
              ('metal', 'opaque', 'plain', '2', '1'),
              ('view', 'opaque', 'plain', '2', '1'),
              ('metal', 'opaque', 'plain', '3', '2'),
              ('view', 'transparent', 'glass', '3', '1')]
with tempfile.TemporaryDirectory(prefix='cghostty-display-probe-') as temporary:
    app = Path(temporary) / 'DisplayProbe.app'
    binary = app / 'Contents/MacOS/DisplayProbe'
    binary.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'DisplayProbe', 'CFBundleName': 'cghostty Display Probe',
        'CFBundleIdentifier': 'com.cjmvpu.cghostty.display-probe', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0'}))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-O',
                    '-parse-as-library', str(ROOT / 'scripts/display-link-probe.swift'), '-o', str(binary)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    for iteration in range(args.repeat):
        for case in cases if iteration % 2 == 0 else reversed(cases):
            output = args.output_directory.resolve() / f'{iteration}-{"-".join(case)}.json'
            if output.exists():
                raise FileExistsError(output)
            launcher = subprocess.Popen(['open', '-n', '-W', str(app), '--args', str(output), *case])
            # Activation is cooperative on recent macOS. Ask the launching
            # process to bring this test app forward; the probe still verifies
            # activation and key-window state before accepting any sample.
            subprocess.run(['osascript', '-e', f'tell application "{app}" to activate'], check=True, timeout=10)
            if launcher.wait(timeout=35) != 0:
                raise RuntimeError('Probe application failed to launch')
            result = json.loads(output.read_text())
            print(output.name, result['error'] or f"{len(result['samples'])} callbacks", flush=True)
            if result['error']:
                raise SystemExit('Probe failed; inspect its recorded state before restarting the matrix.')
