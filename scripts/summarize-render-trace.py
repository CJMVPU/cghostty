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
        "p95": round(values[math.ceil(len(values) * 0.95) - 1], 4),
        "max": round(values[-1], 4),
    }


def summarize(directory):
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
            "draw_interval_ms": distribution(intervals),
            "trail_segments": distribution([row[4] for row in draws]),
            "vsync_interval_ms": event_ms("vsync"),
            "draw_lock_wait_ms": event_ms("draw_lock"),
            "draw_total_ms": event_ms("draw_total"),
            "swap_chain_rebuild_ms": event_ms("rebuild"),
            "main_queue_wait_ms": distribution([row[2] / 1e6 for row in presents if row[4] == 0]),
            "trace_records_dropped": sum(row[2] for row in rows if row[0] == "trace_drop"),
            "layer_assignments": len(presents),
            "synchronous_layer_assignments": sum(row[4] == 1 for row in presents),
            "presentation_drops": {name: drops[code] for code, name in enumerate(
                ["stale", "replaced", "size_mismatch", "invalidated", "target_reused"])},
            "timer_draw_wakes": sum(row[2] == 0 for row in timers),
            "timer_update_wakes": sum(row[2] == 1 for row in timers),
        }
    return result


if __name__ == "__main__":
    print(json.dumps(summarize(pathlib.Path(sys.argv[1])), indent=2))
