#!/usr/bin/env python3
"""Keep the internal GhosttyKit ABI out of native UI and feature code."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "macos/Sources"
# Root Ghostty files form the ABI adapter. App/main.swift only bootstraps the core.
paths = [path for path in SOURCES.rglob("*.swift")
         if path.parent != SOURCES / "Ghostty" and path != SOURCES / "App/main.swift"]

errors = []
for path in sorted(paths):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        code = line.split("//", 1)[0]
        if re.search(r"\bimport GhosttyKit\b|\bghostty_[a-z_]+\b|\bunsafeCValue\b|\bwithCValue\b|\bConfigSchema\b", code):
            errors.append(f"{path.relative_to(ROOT)}:{number}: C ABI belongs in the Ghostty bridge")
        if re.search(r'perform\(action:\s*"', code):
            errors.append(f"{path.relative_to(ROOT)}:{number}: fixed actions need a typed bridge command")

# Configuration values are decoded once; consumers and the observable facade
# cannot grow a second path that queries mutable core values on every read.
value_decoders = {"Ghostty.ConfigSchema.swift"}
snapshot_decoders = {"Ghostty.ConfigSchema.swift", "Ghostty.ConfigSnapshot.swift", "Ghostty.WindowConfig.swift"}
for path in (SOURCES / "Ghostty").glob("*.swift"):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        code = line.split("//", 1)[0]
        if re.search(r"\bghostty_config_get\s*\(", code) and path.name not in value_decoders:
            errors.append(f"{path.relative_to(ROOT)}:{number}: config reads must use the generated typed schema")
        if re.search(r"\bConfigSchema\b", code) and path.name not in snapshot_decoders:
            errors.append(f"{path.relative_to(ROOT)}:{number}: typed config reads belong in snapshot decoding")
        if re.search(r"\bghostty_config_(?:new|clone|free|load_\w+|finalize)\s*\(", code) and path.name != "Ghostty.ConfigHandle.swift":
            errors.append(f"{path.relative_to(ROOT)}:{number}: ConfigHandle owns the core configuration")

if errors:
    raise SystemExit("\n".join(errors))
print(f"PASS: {len(paths)} native UI/feature files use the typed bridge")
