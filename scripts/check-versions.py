#!/usr/bin/env python3
"""Check pinned versions and generate the C/C++ dependency table in pkg/README.md."""

import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TABLE_START = "<!-- dependency-versions:start -->"
TABLE_END = "<!-- dependency-versions:end -->"

# URL shapes, not a second set of version pins. Versions live in build.zig.zon.
SOURCE_ARCHIVES = (
    ("freetype", "FreeType", "https://download.savannah.gnu.org/releases/freetype/freetype-{version}.tar.xz"),
    ("libpng", "libpng", "https://github.com/pnggroup/libpng/archive/refs/tags/v{version}.tar.gz"),
    ("zlib", "zlib", "https://github.com/madler/zlib/releases/download/v{version}/zlib-{version}.tar.gz"),
    ("pcre2", "PCRE2", "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-{version}/pcre2-{version}.tar.gz"),
    ("harfbuzz", "HarfBuzz", "https://github.com/harfbuzz/harfbuzz/releases/download/{version}/harfbuzz-{version}.tar.xz"),
    ("libintl", "GNU gettext / libintl", "https://ftp.gnu.org/pub/gnu/gettext/gettext-{version}.tar.gz"),
    ("highway", "Highway", "https://github.com/google/highway/releases/download/{version}/highway-{version}.tar.gz"),
)


def capture(path, pattern):
    match = re.search(pattern, (ROOT / path).read_text())
    if match is None:
        raise ValueError(f"Missing version record in {path}")
    return match.group(1)


def package_version(package):
    return capture(f"pkg/{package}/build.zig.zon", r'\.version\s*=\s*"([^"]+)"')


def source_url(package, dependency):
    return capture(
        f"pkg/{package}/build.zig.zon",
        rf'\.{dependency}\s*=\s*\.\{{\s*(?://[^\n]*\n\s*)*\.url\s*=\s*"([^"]+)"',
    )


def dependency_table():
    rows = ["| 包 | 锁定源码版本 | 源码记录 |", "| --- | --- | --- |"]
    for package, label, template in SOURCE_ARCHIVES:
        version = package_version(package)
        dependency = "gettext" if package == "libintl" else package
        # GNU gettext and PCRE2 use two-part release names for x.y.0.
        source_version = version.removesuffix(".0") if package in ("libintl", "pcre2") else version
        url = source_url(package, dependency)
        if url != template.format(version=source_version):
            raise ValueError(f"{package} manifest {version} does not match source URL {url}")
        rows.append(f"| {label} | {source_version} | [源码归档]({url}) |")

    simdutf = package_version("simdutf")
    rows.append(f"| simdutf | {simdutf} | [内置源码](simdutf/vendor/simdutf.h) |")

    imgui = package_version("dcimgui").replace("+", "") + "-docking"
    imgui_url = source_url("dcimgui", "imgui")
    if imgui_url != f"https://github.com/ocornut/imgui/archive/refs/tags/v{imgui}.tar.gz":
        raise ValueError(f"dcimgui manifest does not match ImGui source URL {imgui_url}")
    bindings_url = source_url("dcimgui", "bindings")
    bindings = re.fullmatch(
        r"https://github.com/dearimgui/dear_bindings/releases/download/"
        r"(DearBindings_v([0-9.]+)_ImGui_v([^/]+))/\1\.zip",
        bindings_url,
    )
    if bindings is None or bindings[3] != imgui:
        raise ValueError(f"Dear Bindings must target ImGui {imgui}: {bindings_url}")
    rows.append(f"| Dear ImGui | {imgui} | [源码归档]({imgui_url}) |")
    rows.append(f"| Dear Bindings | {bindings[2]}（ImGui {imgui}） | [生成绑定]({bindings_url}) |")

    wuffs_url = source_url("wuffs", "wuffs")
    snapshot = re.fullmatch(r"https://deps\.files\.ghostty\.org/wuffs-([0-9a-f]{40})\.tar\.gz", wuffs_url)
    if snapshot is None:
        raise ValueError(f"Wuffs must identify its source snapshot: {wuffs_url}")
    rows.append(f"| Wuffs | 提交 `{snapshot[1]}` | [源码快照]({wuffs_url}) |")
    return TABLE_START + "\n\n" + "\n".join(rows) + "\n\n" + TABLE_END


def check_dependency_docs(table, update=False):
    path = ROOT / "pkg/README.md"
    text = path.read_text()
    if text.count(TABLE_START) != 1 or text.count(TABLE_END) != 1:
        raise ValueError("pkg/README.md must contain one dependency table marker pair")
    start = text.index(TABLE_START)
    end = text.index(TABLE_END) + len(TABLE_END)
    if end <= start:
        raise ValueError("pkg/README.md dependency table markers are out of order")
    expected = text[:start] + table + text[end:]
    if update:
        path.write_text(expected)
    elif text != expected:
        raise ValueError("Dependency table is stale; run python3 scripts/check-versions.py --update-docs")


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
    output.add_argument("--update-docs", action="store_true", help="refresh only the generated dependency table")
    args = parser.parse_args()
    try:
        toolchain, _ = check_versions()
        # Toolchain installation must remain possible while editing dependency docs.
        if not (args.zig_version or args.zig_sha256):
            check_dependency_docs(dependency_table(), update=args.update_docs)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Version check failed: {error}\n")
    if args.zig_version:
        print(toolchain["version"])
    elif args.zig_sha256:
        print(toolchain["sha256"])
    else:
        print(f"PASS: Zig {toolchain['version']}, dependency source URLs, generated headers and version table")


if __name__ == "__main__":
    main()
