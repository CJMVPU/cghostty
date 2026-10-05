"""Generate deterministic, separate VT files for managed-memory resize timing.

Generation must finish before invoking ghostty-bench; never pipe this generator
into the benchmark. Reuse exact files across baseline and candidate binaries.
"""
import argparse
import hashlib
from pathlib import Path
import random

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--kind", choices=("plain", "grapheme", "osc8"), required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--lines", type=int, default=50_000)
args = parser.parse_args()
if args.lines < 1:
    parser.error("lines must be positive")

rng = random.Random(0xB3)
with args.output.open("wb") as output:
    if args.kind == "osc8":
        # One explicit ID/URI spanning many cells, rows, and source pages.
        # Setup parsing is excluded from the resize measurement.
        uri = "https://example.test/" + "path/" * 20
        link_id = "explicit-id-" + "i" * 80
        output.write(f"\x1b]8;id={link_id};{uri}\x1b\\".encode())
    for line in range(args.lines):
        # All variants have identical base text, logical width, and style.
        if line % 64 == 0:
            output.write(b"\x1b[1m")
        if line % 64 == 32:
            output.write(b"\x1b[m")
        text = bytearray(rng.randrange(97, 123) for _ in range(200))
        for i in range(7, len(text), 8):
            text[i] = 32
        if args.kind == "grapheme":
            content = "".join(chr(cp) + ("\u0301\u0327" if i % 4 == 0 else "")
                              for i, cp in enumerate(text)).encode()
        else:
            content = bytes(text)
        output.write(content + b"\r\n")
    output.write(b"\x1b[m")
    if args.kind == "osc8":
        output.write(b"\x1b]8;;\x1b\\")
print(f"kind={args.kind} lines={args.lines} bytes={args.output.stat().st_size} "
      f"sha256={hashlib.sha256(args.output.read_bytes()).hexdigest()}")
