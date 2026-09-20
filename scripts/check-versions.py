#!/usr/bin/env python3
"""Check the pinned Zig toolchain and generated dependency version records."""

import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def capture(path, pattern):
    match = re.search(pattern, (ROOT / path).read_text())
    if match is None:
        raise ValueError(f"Missing version record in {path}")
    return match.group(1)


def check_versions():
    toolchain = json.loads((ROOT / "scripts/zig-toolchain.json").read_text())
    version = toolchain["version"]
    checksum = toolchain["sha256"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Zig must be pinned to a stable three-part version")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("Zig archive SHA-256 must contain 64 lowercase hex digits")
    required = capture("build.zig.zon", r'\.minimum_zig_version\s*=\s*"([^"]+)"')
    if version != required:
        raise ValueError(f"Zig toolchain {version} does not match build.zig.zon {required}")

    declared = capture("pkg/simdutf/build.zig.zon", r'\.version\s*=\s*"([^"]+)"')
    vendored = capture("pkg/simdutf/vendor/simdutf.h", r'#define SIMDUTF_VERSION "([^"]+)"')
    if declared != vendored:
        raise ValueError(f"simdutf manifest {declared} does not match vendored source {vendored}")

    png = capture("pkg/libpng/build.zig.zon", r'\.version\s*=\s*"([^"]+)"')
    png_config = capture("pkg/libpng/pnglibconf.h", r'libpng version ([0-9.]+)')
    if png != png_config:
        raise ValueError(f"libpng manifest {png} does not match generated configuration {png_config}")

    intl = capture("pkg/libintl/build.zig.zon", r'\.version\s*=\s*"([^"]+)"')
    major, minor, patch = map(int, intl.split("."))
    expected_intl = (major << 16) | (minor << 8) | patch
    for header in ("libintl.h", "libgnuintl.h"):
        generated = capture(f"pkg/libintl/{header}", r'#define LIBINTL_VERSION (0x[0-9a-fA-F]+)')
        if int(generated, 16) != expected_intl:
            raise ValueError(f"libintl manifest {intl} does not match generated {header} {generated}")
    intl_config = capture("pkg/libintl/config.h", r'#define PACKAGE_VERSION "([^"]+)"')
    parts = [int(part) for part in intl_config.split(".")]
    if (parts + [0, 0])[:3] != [major, minor, patch]:
        raise ValueError(f"libintl manifest {intl} does not match generated configuration {intl_config}")
    return toolchain, vendored


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--zig-version", action="store_true")
    output.add_argument("--zig-sha256", action="store_true")
    args = parser.parse_args()
    try:
        toolchain, simdutf = check_versions()
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Version check failed: {error}\n")
    if args.zig_version:
        print(toolchain["version"])
    elif args.zig_sha256:
        print(toolchain["sha256"])
    else:
        print(f"PASS: Zig {toolchain['version']}, simdutf {simdutf}, libpng and libintl version records")


if __name__ == "__main__":
    main()
