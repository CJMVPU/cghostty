#!/usr/bin/env python3
"""Reconstruct the exact instrumented shaper sources used for the baseline.

Writes only the two explicitly supplied output files. Run in this repository;
copy outputs into an independent baseline checkout before serial testing.
"""
import argparse
import hashlib
import pathlib
import subprocess

BASE = "641d6f29fd86260afbd3ed0bf91416cd17b1aed3"
PROBE = "d5376e2141f3c8d753ccac3834f3b3912a77d8e9"
ROOT = pathlib.Path(__file__).resolve().parents[2]


def source(commit, path):
    return subprocess.check_output(
        ["git", "show", f"{commit}:{path}"], cwd=ROOT, text=True
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-output", required=True, type=pathlib.Path)
    parser.add_argument("--coretext-output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    run = source(BASE, "src/font/shaper/run.zig")
    run = run.replace('const std = @import("std");\n',
                      'const std = @import("std");\nconst builtin = @import("builtin");\n', 1)
    run = run.replace("    i: usize = 0,\n", """    i: usize = 0,
    testing_stats: TestingStats = .{},

    const TestingStats = if (builtin.is_test) struct {
        tail_scan_cells: usize = 0,
    } else struct {};
""", 1)
    run = run.replace("            for (0..cells.len) |i| {\n",
                      "            for (0..cells.len) |i| {\n"
                      "                if (comptime builtin.is_test) self.testing_stats.tail_scan_cells += 1;\n", 1)
    after = source(PROBE, "src/font/shaper/coretext.zig")
    start = after.index('test "run iterator tail scan probe remains linear across short runs" {')
    end = after.index('test "run iterator caches empty row tail bounds" {', start)
    coretext = source(BASE, "src/font/shaper/coretext.zig").replace(
        'test "run iterator" {', after[start:end] + 'test "run iterator" {', 1)
    for contents, output, expected in (
        (run, args.run_output, "b5935305e1c8989ed20ae1f4f27a0775610f0bdbdbd17136f8e1b1dec54eeab7"),
        (coretext, args.coretext_output, "52e6ee7708689cfe0e0e32f94d55f9f02419e373d51e72e9b60c528462815b07"),
    ):
        digest = hashlib.sha256(contents.encode()).hexdigest()
        if digest != expected:
            raise RuntimeError(f"baseline reconstruction mismatch: {output}: {digest}")
        output.write_text(contents)
        print(f"{digest}  {output}")


if __name__ == "__main__":
    main()
