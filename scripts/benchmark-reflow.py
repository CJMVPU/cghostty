#!/usr/bin/env python3
"""Serial Terminal.resize baseline; never interprets process wall time as resize.

Run only after building ghostty-bench in ReleaseFast. Corpus generation is a
separate invocation, and every process uses the identical saved corpus.

Example:
    python3 scripts/benchmark-reflow.py --generate --corpus=/tmp/reflow.vt
    python3 scripts/benchmark-reflow.py --corpus=/tmp/reflow.vt \
        --binary=zig-out/bin/ghostty-bench --output=/tmp/reflow-results

The scrollback flags are budgets, not verified retained-history sizes. Inspect
raw_bytes_before and rows_before/after in the output: corpus bytes cannot predict
page backing bytes because page capacity, styles, and wrapping affect storage.
"""

import argparse
import hashlib
import json
import math
import random
import re
import statistics
import subprocess
from pathlib import Path


def percentile(values, fraction):
    values = sorted(values)
    position = (len(values) - 1) * fraction
    low = math.floor(position)
    high = math.ceil(position)
    return values[low] + (values[high] - values[low]) * (position - low)


def generate(path, lines):
    rng = random.Random(0xB3)
    with path.open("wb") as output:
        for i in range(lines):
            if i % 64 == 0:
                output.write(b"\x1b[48;2;20;40;60m")
            if i % 64 == 32:
                output.write(b"\x1b[m")
            if i % 16 != 15:
                size = rng.randrange(30, 300)
                text = bytearray(rng.randrange(97, 123) for _ in range(size))
                for j in range(7, size, 8):
                    text[j] = 32
                if i % 8 == 7:
                    # Fixed wide/combining content exercises reflow boundaries.
                    text[8:9] = "漢e\u0301".encode()
                output.write(text)
            output.write(b"\r\n")
        output.write(b"\x1b[m")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--generate", action="store_true")
    parser.add_argument("--corpus-lines", type=int, default=300_000,
                        help="fixed-seed generated line count; only used with --generate")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--repeats", type=int, default=15)
    args = parser.parse_args()
    if args.corpus_lines < 1:
        parser.error("corpus-lines must be positive")
    if args.generate:
        generate(args.corpus, args.corpus_lines)
        print(f"saved corpus lines={args.corpus_lines} bytes={args.corpus.stat().st_size}",
              flush=True)
        return
    if args.binary is None or args.output is None:
        parser.error("measurement requires --binary and --output")
    if args.warmups < 0 or args.repeats < 1:
        parser.error("warmups must be nonnegative and repeats positive")

    args.output.mkdir(parents=True, exist_ok=True)
    report = {
        "corpus": str(args.corpus.resolve()),
        "corpus_bytes": args.corpus.stat().st_size,
        "corpus_sha256": hashlib.sha256(args.corpus.read_bytes()).hexdigest(),
        "binary": str(args.binary.resolve()),
        "warmups": args.warmups,
        "repeats": args.repeats,
        "scope": "Direct Terminal.resize cycle wall time; no IO lock contention or UI frames. "
        "Peak RSS covers the entire process including setup and cold preparation. "
        "Page backing values are estimates from PageList memory metadata. "
        "Scrollback limits are budgets; report actual retained page bytes and rows "
        "rather than assuming the corpus fills each budget.",
        "configurations": [],
    }
    for size in (5_000_000, 50_000_000, 200_000_000):
        for cold in (False, True):
            label = f"{size}-{'cold' if cold else 'resident'}"
            command = [
                "/usr/bin/time", "-l", str(args.binary.resolve()),
                "+terminal-resize", "--mode=cols", "--loops=1",
                "--terminal-cols=120", "--resize-cols=60", "--terminal-rows=80",
                "--fill-lines=0", f"--scrollback-bytes={size}",
                f"--data={args.corpus.resolve()}", "--report=true",
                f"--cold={'true' if cold else 'false'}",
            ]
            config = {"label": label, "scrollback_budget_bytes": size,
                      "command": command, "runs": []}
            report["configurations"].append(config)
            for index in range(args.warmups + args.repeats):
                result = subprocess.run(command, capture_output=True, text=True)
                log = result.stdout + result.stderr
                log_name = f"{label}-{index:02d}.log"
                (args.output / log_name).write_text(log)
                if result.returncode:
                    raise RuntimeError(f"benchmark failed; see {log_name}")
                samples = []
                for line in log.splitlines():
                    if line.startswith("terminal-resize cycle="):
                        samples.append({key: int(value) for key, value in
                                        re.findall(r"(\w+)=(\d+)", line)})
                if len(samples) != 25:
                    raise RuntimeError(f"expected 25 cycle samples; see {log_name}")
                if cold and any(sample["compressed_pages"] == 0 for sample in samples):
                    raise RuntimeError(f"cold measurement lacks compressed pages; see {log_name}")
                if not cold and any(sample["compressed_pages"] for sample in samples):
                    raise RuntimeError(f"resident measurement includes compressed pages; see {log_name}")
                rss = re.search(r"(\d+)\s+maximum resident set size", log)
                if rss is None:
                    raise RuntimeError(f"missing macOS peak RSS; see {log_name}")
                if index >= args.warmups:
                    memory = {}
                    for line in log.splitlines():
                        match = re.match(r"terminal-resize memory=(before|after) ", line)
                        if match:
                            memory[match[1]] = {key: int(value) for key, value in
                                               re.findall(r"(\w+)=(\d+)", line)}
                    if set(memory) != {"before", "after"}:
                        raise RuntimeError(f"missing before/after page memory; see {log_name}")
                    config["runs"].append({
                        "log": log_name, "peak_rss_bytes": int(rss[1]),
                        "page_memory": memory, "samples": samples,
                    })
                print(f"finished {label} run={index} warmup={index < args.warmups}", flush=True)
                (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")

            # Report both the first cycle and later cycles: shrinking a full
            # history may discard rows under the scrollback budget. Combining
            # these silently would imply equivalent work that did not occur.
            first = [run["samples"][0]["resize_ns"] for run in config["runs"]]
            later = [sample["resize_ns"] for run in config["runs"]
                     for sample in run["samples"][1:]]
            config["summary"] = {
                "first_cycle_p50_ns": statistics.median(first),
                "first_cycle_p95_ns": percentile(first, 0.95),
                "later_cycle_p50_ns": statistics.median(later),
                "later_cycle_p95_ns": percentile(later, 0.95),
                "peak_rss_p50_bytes": statistics.median(
                    run["peak_rss_bytes"] for run in config["runs"]),
                "first_cycle_raw_bytes_before_p50": statistics.median(
                    run["samples"][0]["raw_bytes_before"] for run in config["runs"]),
                "first_cycle_rows_before_p50": statistics.median(
                    run["samples"][0]["rows_before"] for run in config["runs"]),
                "last_cycle_rows_after_p50": statistics.median(
                    run["samples"][-1]["rows_after"] for run in config["runs"]),
            }
            print(f"summary {label}: {json.dumps(config['summary'])}", flush=True)
            (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
