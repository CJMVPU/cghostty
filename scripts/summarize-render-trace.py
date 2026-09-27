#!/usr/bin/env python3
"""Summarize renderer CSVs or xcresulttool benchmark attachments as JSON.

Usage: summarize-render-trace.py TRACE_OR_ATTACHMENTS_DIR
All comparisons must use identical build configuration/workloads. Draw time is
wall time in the CPU draw path (including frame-slot waits), not CPU usage.
"""
import collections
import json
import math
import pathlib
import sys


def distribution(values):
    if not values:
        return None
    values = sorted(values)
    return {
        "count": len(values),
        "mean": round(sum(values) / len(values), 4),
        "median": round((values[(len(values) - 1) // 2] + values[len(values) // 2]) / 2, 4),
        "p99": round(values[math.ceil(len(values) * 0.99) - 1], 4),
        "p95": round(values[math.ceil(len(values) * 0.95) - 1], 4),
        "max": round(values[-1], 4),
    }


def summarize(directory):
    if (directory / "samples.json").exists():
        return summarize_reference(directory / "samples.json")
    groups = collections.defaultdict(list)
    manifest = directory / "manifest.json"
    files = []
    if manifest.exists():
        for test in json.loads(manifest.read_text()):
            for attachment in test["attachments"]:
                name = attachment["suggestedHumanReadableName"]
                if name.startswith("perf-"):
                    files.append(("-".join(name.split("-")[1:3]), directory / attachment["exportedFileName"]))
    else:
        files = [("local", path) for path in sorted(directory.glob("render-*.csv"))]
    for group, path in files:
        rows = []
        for line in path.read_text().splitlines():
            event, *numbers = line.split(",")
            rows.append((event, *map(int, numbers)))
        groups[group].append(rows)
    result = {}
    for group, surfaces in sorted(groups.items()):
        rows = [row for surface in surfaces for row in surface]
        draws = [row for row in rows if row[0] == "draw"]
        gpu = [row for row in rows if row[0] == "gpu"]
        timers = [row for row in rows if row[0] == "timer"]
        overlays = [row for row in rows if row[0] == "overlay"]
        intervals = []
        for surface in surfaces:
            times = sorted(row[1] for row in surface if row[0] == "draw")
            intervals.extend((b - a) / 1e6 for a, b in zip(times, times[1:]))
        displayed = []
        submit_to_display = []
        prediction_error = []
        callback_to_submit = []
        callback_to_deadline = []
        deadline_to_prediction = []
        submitted_after_deadline = 0
        for surface in surfaces:
            # Sequence numbers are local to one renderer; never join surfaces.
            submissions = {r[3]: r[2] for r in surface if r[0] == "present_submit"}
            predictions = {r[4]: r[3] for r in surface if r[0] == "metal_tick"}
            deadlines = {r[4]: r[2] for r in surface if r[0] == "metal_tick"}
            callbacks = {r[3]: r[2] for r in surface if r[0] == "metal_callback"}
            for sequence, submitted in submissions.items():
                if sequence in callbacks:
                    callback_to_submit.append((submitted - callbacks[sequence]) / 1e6)
                if sequence in callbacks and sequence in deadlines:
                    callback_to_deadline.append((deadlines[sequence] - callbacks[sequence]) / 1e6)
                if sequence in predictions and sequence in deadlines:
                    deadline_to_prediction.append((predictions[sequence] - deadlines[sequence]) / 1e6)
                if sequence in deadlines and submitted > deadlines[sequence]:
                    submitted_after_deadline += 1
            for row in surface:
                if row[0] != "displayed" or row[2] == 0:
                    continue
                displayed.append(row)
                if row[3] in submissions and row[2] >= submissions[row[3]]:
                    submit_to_display.append((row[2] - submissions[row[3]]) / 1e6)
                if row[3] in predictions:
                    prediction_error.append((row[2] - predictions[row[3]]) / 1e6)
        presents = [row for row in rows if row[0] == "present"]
        drops = collections.Counter(row[2] for row in rows if row[0] == "present_drop")
        def event_ms(event):
            return distribution([row[2] / 1e6 for row in rows if row[0] == event])
        result[group] = {
            "surfaces": len(surfaces),
            "draws": len(draws),
            "copied_cell_bytes": sum(row[3] for row in draws),
            "frames_reusing_cells": sum(row[3] == 0 for row in draws),
            "overlay_reference_instances": sum(row[2] for row in overlays) if overlays else None,
            "overlay_submitted_instances": sum(row[3] for row in overlays) if overlays else None,
            "overlay_scissor_pixels": distribution([row[4] for row in overlays]),
            "draw_wall_ms": distribution([row[2] / 1e6 for row in draws]),
            "gpu_execution_ms": distribution([row[2] / 1e6 for row in gpu]),
            "snapshot_wall_ms": event_ms("snapshot"),
            "snapshot_gpu_ms": event_ms("snapshot_gpu"),
            "draw_interval_ms": distribution(intervals),
            "trail_segments": distribution([row[4] for row in draws]),
            "vsync_interval_ms": event_ms("vsync"),
            "draw_lock_wait_ms": event_ms("draw_lock"),
            "draw_total_ms": event_ms("draw_total"),
            "swap_chain_rebuild_ms": event_ms("rebuild"),
            "main_queue_wait_ms": distribution([row[2] / 1e6 for row in presents if row[4] == 0]),
            "trace_records_dropped": sum(row[2] for row in rows if row[0] == "trace_drop"),
            "layer_assignments": len(presents),
            "metal_displayed_frames": len(displayed),
            "metal_submit_to_display_ms": distribution(submit_to_display),
            "metal_prediction_error_ms": distribution(prediction_error),
            "metal_callback_to_submit_ms": distribution(callback_to_submit),
            "metal_callback_to_deadline_ms": distribution(callback_to_deadline),
            "metal_deadline_to_prediction_ms": distribution(deadline_to_prediction),
            "metal_submitted_after_deadline": submitted_after_deadline,
            "metal_resumes": sum(r[2] == 0 for r in rows if r[0] == "metal_state"),
            "metal_pauses": sum(r[2] == 1 for r in rows if r[0] == "metal_state"),
            "metal_preferred_frame_latencies": sorted({r[3] / 1000 for r in rows if r[0] == "metal_state"}),
            "synchronous_layer_assignments": sum(row[4] == 1 for row in presents),
            "presentation_drops": {name: drops[code] for code, name in enumerate(
                ["stale", "replaced", "size_mismatch", "invalidated", "target_reused"])},
            "timer_draw_wakes": sum(row[2] == 0 for row in timers),
            "timer_update_wakes": sum(row[2] == 1 for row in timers),
        }
    return result


def summarize_reference(path):
    """Minimal clear-only control, excluding the first 20 warm-up frames."""
    data = json.loads(path.read_text())
    samples = [s for s in data["samples"] if s["sequence"] >= 20 and s["displayed"] > 0]
    metrics = {}
    for name, start, end in [
        ("metal_submit_to_display_ms", "submit", "displayed"),
        ("metal_callback_to_submit_ms", "callback", "submit"),
        ("metal_callback_to_deadline_ms", "callback", "deadline"),
        ("metal_deadline_to_prediction_ms", "deadline", "prediction"),
        ("metal_prediction_error_ms", "prediction", "displayed"),
    ]:
        metrics[name] = distribution([(s[end] - s[start]) * 1000 for s in samples])
    return {"reference": {
        "preferred_frame_latency": data["latency"],
        "requested_maximum_rate": data["requestedMaximum"],
        "screen_maximum_fps": data["screenMaximumFPS"],
        "warmup_frames": 20,
        "valid_samples": len(samples),
        **metrics,
    }}


if __name__ == "__main__":
    print(json.dumps(summarize(pathlib.Path(sys.argv[1])), indent=2))
