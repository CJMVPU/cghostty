#!/usr/bin/env python3
"""Summarize xcresulttool exported renderer benchmark attachments as JSON.

Usage: summarize-render-trace.py ATTACHMENTS_DIR
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
    }


def summarize(directory):
    groups = collections.defaultdict(list)
    for test in json.loads((directory / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            name = attachment["suggestedHumanReadableName"]
            if not name.startswith("perf-"):
                continue
            group = "-".join(name.split("-")[1:3])
            rows = []
            for line in (directory / attachment["exportedFileName"]).read_text().splitlines():
                event, *numbers = line.split(",")
                rows.append((event, *map(int, numbers)))
            groups[group].append(rows)
    result = {}
    for group, surfaces in sorted(groups.items()):
        rows = [row for surface in surfaces for row in surface]
        draws = [row for row in rows if row[0] == "draw"]
        gpu = [row for row in rows if row[0] == "gpu"]
        timers = [row for row in rows if row[0] == "timer"]
        intervals = []
        for surface in surfaces:
            times = [row[1] for row in surface if row[0] == "draw"]
            intervals.extend((b - a) / 1e6 for a, b in zip(times, times[1:]))
        result[group] = {
            "surfaces": len(surfaces),
            "draws": len(draws),
            "copied_cell_bytes": sum(row[3] for row in draws),
            "frames_reusing_cells": sum(row[3] == 0 for row in draws),
            "draw_wall_ms": distribution([row[2] / 1e6 for row in draws]),
            "gpu_execution_ms": distribution([row[2] / 1e6 for row in gpu]),
            "draw_interval_ms": distribution(intervals),
            "trail_segments": distribution([row[4] for row in draws]),
            "timer_draw_wakes": sum(row[2] == 0 for row in timers),
            "timer_update_wakes": sum(row[2] == 1 for row in timers),
        }
    return result


if __name__ == "__main__":
    print(json.dumps(summarize(pathlib.Path(sys.argv[1])), indent=2))
