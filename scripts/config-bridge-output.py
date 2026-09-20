#!/usr/bin/env python3
"""Install or verify the native config bridge emitted by Zig reflection."""
import argparse
import difflib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("generated", type=Path)
parser.add_argument("destination", type=Path)
parser.add_argument("--update", action="store_true")
args = parser.parse_args()
expected = args.generated.read_bytes()
if args.update:
    args.destination.write_bytes(expected)
    print("Updated native config bridge")
else:
    actual = args.destination.read_bytes() if args.destination.exists() else b""
    if actual != expected:
        diff = difflib.unified_diff(actual.decode().splitlines(), expected.decode().splitlines(),
                                    fromfile=str(args.destination), tofile="generated", lineterm="")
        print("\n".join(diff))
        raise SystemExit("Native config bridge is stale. Run: zig build update-config-bridge")
    print("PASS: native config bridge matches Zig field names and C storage types")
