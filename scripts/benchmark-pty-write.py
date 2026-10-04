#!/usr/bin/env python3
"""Run headless PTY resource probes serially; no revisions are switched.

Example (run from the revision to measure; don't run while other builds run):
  python3 scripts/benchmark-pty-write.py baseline --out /tmp/cghostty-audit-pty-baseline
  python3 scripts/benchmark-pty-write.py after --out /tmp/cghostty-audit-pty-after

The project wrapper serializes each build/test. RESOURCE_METRIC timings measure
only enqueue/drain, while wrapper_wall_seconds includes build/test startup and
is not a product speed metric. One warmup and three repeats are intended to
validate resource counts and identify large effects, not precise timing claims.
Use --warmups 3 --repeats 15 for stronger timing evidence, with the same settings
for both revisions and no other benchmark/build load on the machine.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import time


def git(repo, *arguments):
    return subprocess.check_output(['git', '-C', str(repo), *arguments], text=True).strip()


def source_hash(repo, name):
    return hashlib.sha256((repo / name).read_bytes()).hexdigest()


def save(out, result):
    tmp = out / 'results.json.tmp'
    tmp.write_text(json.dumps(result, indent=2) + '\n')
    tmp.replace(out / 'results.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['baseline', 'after'])
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--warmups', type=int, default=1)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--sizes', type=int, nargs='+', default=[1, 8, 32])
    parser.add_argument('--modes', nargs='+', choices=['fast', 'slow', 'paused'], default=['fast', 'slow', 'paused'])
    args = parser.parse_args()
    if args.warmups < 1 or args.repeats < 1 or any(v < 1 or v > 32 for v in args.sizes):
        parser.error('Use at least one warmup/repeat and sizes from 1 to 32 MiB.')
    repo = args.repo.resolve()
    out = args.out.resolve()
    if not out.is_relative_to(Path('/tmp')) and not out.is_relative_to(Path('/private/tmp')):
        parser.error('Output must stay under /tmp; corpus/results are not repository files.')
    out.mkdir(parents=True, exist_ok=False)
    command = [sys.executable, 'scripts/build.py', 'test', '-Doptimize=ReleaseFast',
               '-Dtest-optimize=ReleaseFast', '-Dtest-filter=PTY write pressure probe']
    env_base = os.environ.copy()
    bundled_zig = repo / '.tools/zig-aarch64-macos-0.16.0'
    if (bundled_zig / 'zig').is_file():
        env_base['PATH'] = str(bundled_zig) + os.pathsep + env_base.get('PATH', '')
    result = {
        'phase': args.phase,
        'revision': git(repo, 'rev-parse', 'HEAD'),
        'branch': git(repo, 'branch', '--show-current'),
        'worktree_status': git(repo, 'status', '--short'),
        'source_sha256': {name: source_hash(repo, name) for name in
                          ['src/termio/Exec.zig', 'src/termio/pty_write_probe.zig']},
        'platform': platform.platform(),
        'command': command,
        'warmups': args.warmups,
        'repeats': args.repeats,
        'timing_limit': 'Resource-count probe; three samples do not support precise timing claims.',
        'cases': [],
    }
    save(out, result)
    for mib in args.sizes:
        for mode in args.modes:
            case = {'mib': mib, 'mode': mode, 'runs': [], 'medians': {}}
            result['cases'].append(case)
            for index in range(args.warmups + args.repeats):
                warmup = index < args.warmups
                log_name = f'{mib}mib-{mode}-{index:02d}.log'
                env = env_base.copy()
                env['CGHOSTTY_PTY_PROBE_MIB'] = str(mib)
                env['CGHOSTTY_PTY_PROBE_MODE'] = mode
                print(f'{args.phase}: {mib} MiB {mode}, {"warmup" if warmup else "sample"} {index + 1}', flush=True)
                started = time.monotonic()
                with (out / log_name).open('w') as log:
                    completed = subprocess.run(command, cwd=repo, env=env,
                                               stdout=log, stderr=subprocess.STDOUT)
                    code = completed.returncode
                elapsed = time.monotonic() - started
                content = (out / log_name).read_text(errors='replace')
                matches = re.findall(r'RESOURCE_METRIC ([^\r\n]+)', content)
                metrics = {}
                if len(matches) == 1:
                    for key, value in re.findall(r'(\w+)=([^\s]+)', matches[0]):
                        metrics[key] = value if key == 'mode' else int(value)
                run = {'warmup': warmup, 'returncode': code, 'log': log_name,
                       'wrapper_wall_seconds': elapsed, 'metrics': metrics}
                case['runs'].append(run)
                save(out, result)
                if code != 0 or metrics.get('pty_bytes') != mib * 1024 * 1024 or metrics.get('mode') != mode:
                    print(f'Failed or missing metrics: {out / log_name}', file=sys.stderr)
                    return 1
            samples = [run['metrics'] for run in case['runs'] if not run['warmup']]
            case['medians'] = {key: statistics.median([sample[key] for sample in samples])
                               for key in samples[0] if key != 'mode'}
            save(out, result)
            print(json.dumps({'mib': mib, 'mode': mode, 'medians': case['medians']}), flush=True)
    result['complete'] = True
    result['final_source_sha256'] = {name: source_hash(repo, name) for name in result['source_sha256']}
    save(out, result)
    print(f'Saved {out / "results.json"}', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
