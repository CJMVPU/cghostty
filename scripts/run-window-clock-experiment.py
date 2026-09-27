#!/usr/bin/env python3
"""Run one compiled full-terminal clock experiment with isolated config and PTYs."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('app', type=Path)
p.add_argument('directory', type=Path)
p.add_argument('--samples', type=int, default=200)
p.add_argument('--phases', help='Comma-separated phase names; default runs the full matrix')
p.add_argument('--drawables', type=int, choices=[2, 3], default=3)
a = p.parse_args()
if a.samples < 1:
    p.error('--samples must be positive')
root = a.directory.resolve()
root.mkdir(parents=True, exist_ok=False)
(root / 'vim.txt').write_text(''.join(f'clock-row-{i:04d} abcdefghijklmnopqrstuvwxyz\n' for i in range(1000)))
shutil.copyfile(ROOT / 'scripts/clock-experiment-workload.py', root / 'workload.py')
trace = root / 'trace'
trace.mkdir()
config = root / 'config.ghostty'
config.write_text(f'''shell-integration = none
confirm-close-surface = false
quit-after-last-window-closed = false
cursor-style-blink = false
cursor-effect = true
cursor-effect-mode = classic
smooth-scroll = true
font-size = 10
background-opacity = 1
render-trace = true
render-trace-directory = {trace}
''')
nvim = shutil.which('nvim')
if nvim is None:
    raise SystemExit('nvim is required for real editor workloads')
values = dict(CGHOSTTY_CONFIG_PATH=str(config), CGHOSTTY_CLOCK_OUTPUT=str(root / 'result.json'),
              CGHOSTTY_CLOCK_WORKLOAD=str(root / 'workload.py'),
              CGHOSTTY_CLOCK_NVIM=nvim, CGHOSTTY_CLOCK_SAMPLES=str(a.samples),
              CGHOSTTY_CLOCK_DRAWABLES=str(a.drawables), GHOSTTY_USER_DEFAULTS_SUITE='clock-experiment-' + uuid.uuid4().hex)
if a.phases:
    values['CGHOSTTY_CLOCK_PHASES'] = a.phases
command = ['open', '-n', '-W']
for k, v in values.items():
    command += ['--env', f'{k}={v}']
command += [str(a.app.resolve()), '--args', '-ApplePersistenceIgnoreState', 'YES']
launcher = subprocess.Popen(command)
subprocess.run(['osascript', '-e', f'tell application "{a.app.resolve()}" to activate'], check=True, timeout=60)
if launcher.wait(timeout=900) != 0:
    raise SystemExit('Experiment failed to launch')
result = json.loads((root / 'result.json').read_text())
print(json.dumps(result, indent=2))
if result['error'] or any(x['failed'] for x in result['phases']):
    raise SystemExit('Experiment failed; keep diagnostic output and exclude this run.')
