#!/usr/bin/env python3
"""Summarize standalone foreground probes; presentedTime is not input-to-photon."""
import argparse
import json
import math
import statistics
from pathlib import Path


def distribution(values):
    if not values:
        return None
    values = sorted(values)
    return {"count": len(values), "median": round(statistics.median(values), 4),
            "p95": round(values[math.ceil(len(values) * .95) - 1], 4),
            "p99": round(values[math.ceil(len(values) * .99) - 1], 4),
            "max": round(values[-1], 4)}


def summarize(data):
    measured = [r for r in data["samples"] if r["sequence"] >= data["warmupFrames"]]
    shown = [r for r in measured if r["displayed"] > 0]
    times = sorted(r["displayed"] for r in shown)
    delta = lambda end, start: distribution([(r[end] - r[start]) * 1000 for r in shown])
    return {"arguments": data["arguments"], "device": data["device"], "screen": data["screen"],
            "os": data["os"], "screen_max_fps": data["screenMaximumFPS"], "error": data["error"],
            "samples": len(measured), "displayed": len(shown), "not_displayed": len(measured) - len(shown),
            "all_foreground": all(r["active"] and r["key"] for r in measured) if measured else False,
            "callback_to_submit_ms": delta("submit", "callback"),
            "submit_to_display_ms": delta("displayed", "submit"),
            "callback_to_display_ms": delta("displayed", "callback"),
            "display_interval_ms": distribution([(b - a) * 1000 for a, b in zip(times, times[1:])]),
            "drawable_acquire_ms": distribution([r["acquire"] * 1000 for r in shown]),
            "deadline_to_prediction_ms": delta("prediction", "deadline")
            if shown and all(r["prediction"] > 0 for r in shown) else None}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    print(json.dumps({p.stem: summarize(json.loads(p.read_text()))
                      for p in sorted(args.directory.glob("*.json"))}, indent=2))
