#!/usr/bin/env python3
"""Join full-terminal experiment phases to render traces, preserving measurement limits."""
import argparse
import collections
import importlib.util
import json
from pathlib import Path
import statistics
import tempfile

spec = importlib.util.spec_from_file_location('render_trace', Path(__file__).with_name('summarize-render-trace.py'))
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


def clock_metrics(rows):
    callbacks = {r[3]: (r[2], r[4]) for r in rows if r[0] == 'clock_callback'}
    targets = {r[4]: (r[2], r[3]) for r in rows if r[0] == 'clock_target'}
    predictions = {r[4]: r[3] for r in rows if r[0] == 'metal_tick'}
    starts = {r[3]: r[2] for r in rows if r[0] == 'present_submit'}
    displayed = {r[3]: r[2] for r in rows if r[0] == 'displayed'}
    states = [r for r in rows if r[0] == 'clock_state']
    intervals, normalized, callback_intervals = [], [], []
    windows = collections.defaultdict(list)
    for seq, (when, window) in callbacks.items():
        windows[window].append((when, seq))
    for window, frames in windows.items():
        frames.sort()
        for (previous_time, previous), (current_time, current) in zip(frames, frames[1:]):
            # A paused clock has no obligation to produce intervening frames.
            if any(r[3] == window and r[4] == 1 and previous_time <= r[2] < current_time for r in states):
                continue
            callback_intervals.append((current_time - previous_time) / 1e6)
        visible = [(when, seq, displayed[seq]) for when, seq in frames if displayed.get(seq, 0) > 0]
        for (a, previous, shown_a), (b, current, shown_b) in zip(visible, visible[1:]):
            if any(r[3] == window and r[4] == 1 and a <= r[2] < b for r in states):
                continue
            if shown_b <= shown_a or current not in targets:
                continue
            period = targets[current][1]
            if period <= 0:
                continue
            intervals.append((shown_b - shown_a) / 1e6)
            normalized.append((shown_b - shown_a) / period)
    return {
        'callbacks': len(callbacks),
        'early_prepare_ms': trace.distribution([r[2] / 1e6 for r in rows if r[0] == 'window_prepare_early']),
        'prediction_absolute_error_ms': trace.distribution([abs(shown - predictions[seq]) / 1e6
            for seq, shown in displayed.items() if shown > 0 and seq in predictions]),
        'clock_wakes': sum(r[0] == 'clock_wake' for r in rows),
        'pauses': sum(r[4] == 1 for r in states), 'resumes': sum(r[4] == 0 for r in states),
        'skipped_busy': sum(r[0] == 'clock_skip' and r[4] == 1 for r in rows),
        'drawable_nil': sum(r[0] == 'drawable_acquire' and r[4] == 1 for r in rows),
        'drawable_acquire_ms': trace.distribution([r[2] / 1e6 for r in rows if r[0] == 'drawable_acquire']),
        'callback_interval_ms': trace.distribution(callback_intervals),
        'continuous_display_interval_ms': trace.distribution(intervals),
        'continuous_display_stddev_ms': statistics.pstdev(intervals) if intervals else None,
        'long_display_interval_ratio': sum(x > 1.5 for x in normalized) / len(normalized) if normalized else None,
        'displayed_zero': sum(v == 0 for v in displayed.values()),
        'submitted_without_callback': len(starts.keys() - displayed.keys()),
        'callback_to_display_ms': trace.distribution([(shown - callbacks[seq][0]) / 1e6
            for seq, shown in displayed.items() if shown > 0 and seq in callbacks]),
        'target_residual_ms': trace.distribution([(shown - targets[seq][0]) / 1e6
            for seq, shown in displayed.items() if shown > 0 and seq in targets]),
    }


def summarize(directory):
    result = json.loads((directory / 'result.json').read_text())
    sources = {}
    for file in (directory / 'trace').glob('render-*.csv'):
        sources[file.name] = [(parts[0], *map(int, parts[1:]))
                             for line in file.read_text().splitlines() if (parts := line.split(','))]
    rows = [r for values in sources.values() for r in values]
    result['all_frames'] = clock_metrics(rows)
    result['trace_records_dropped'] = sum(r[2] for r in rows if r[0] == 'trace_drop')
    for phase in result['phases']:
        bounds = [r[1] for r in rows if r[0] == 'experiment_phase' and r[3] == phase['id']]
        if len(bounds) != 2:
            phase['trace_error'] = 'missing phase boundary'
            continue
        lo, hi = min(bounds), max(bounds)
        subset = [r for r in rows if lo <= r[1] <= hi]
        with tempfile.TemporaryDirectory(prefix='clock-summary-') as temporary:
            for name, values in sources.items():
                selected = [r for r in values if lo <= r[1] <= hi]
                if selected:
                    Path(temporary, name).write_text(''.join(','.join(map(str, r)) + '\n' for r in selected))
            metrics = trace.summarize(Path(temporary))['local']
        phase['render'] = metrics
        phase['clock'] = clock_metrics(subset)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.directory), indent=2))
