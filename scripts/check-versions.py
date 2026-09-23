#!/usr/bin/env python3
"""Check pinned versions and generate the C/C++ dependency table in pkg/README.md."""

import argparse
import json
from pathlib import Path
import re
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TABLE_START = "<!-- dependency-versions:start -->"
TABLE_END = "<!-- dependency-versions:end -->"

# URL shapes, not a second set of version pins. Versions live in build.zig.zon.
SOURCE_ARCHIVES = (
    ("pcre2", "PCRE2", "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-{version}/pcre2-{version}.tar.gz"),
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
        dependency = package
        # PCRE2 uses two-part release names for x.y.0.
        source_version = version.removesuffix(".0") if package == "pcre2" else version
        url = source_url(package, dependency)
        if url != template.format(version=source_version):
            raise ValueError(f"{package} manifest {version} does not match source URL {url}")
        rows.append(f"| {label} | {source_version} | [源码归档]({url}) |")

    simdutf = package_version("simdutf")
    rows.append(f"| simdutf | {simdutf} | [内置源码](simdutf/vendor/simdutf.h) |")

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

    return toolchain, vendored


def check_app_version(*, sync=False, build_number=None, tag=None, app=None):
    version = capture('build.zig.zon', r'\.version\s*=\s*"([^"]+)"')
    marketing = re.split(r'[-+]', version)[0]
    project = ROOT / 'macos/Ghostty.xcodeproj/project.pbxproj'
    # Resolve the app target's three configuration IDs, leaving test targets alone.
    data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))
    objects = data['objects']
    target = next(obj for obj in objects.values() if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'Ghostty')
    configs = objects[target['buildConfigurationList']]['buildConfigurations']
    numbers = {str(objects[key]['buildSettings']['CURRENT_PROJECT_VERSION']) for key in configs}
    if build_number is None and len(numbers) != 1:
        raise ValueError('App build numbers differ; use --sync-app-version --build-number N')
    number = str(build_number) if build_number is not None else numbers.pop()
    if not number.isdigit() or int(number) < 1:
        raise ValueError('App build number must be a positive integer')
    text = project.read_text()
    for key in configs:
        settings = objects[key]['buildSettings']
        if sync:
            pattern = rf'({re.escape(key)} /\* [^\n]+ \*/ = \{{.*?)(\n\t\t\}};)'
            def update(match):
                block = re.sub(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {marketing};', match[1])
                block = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', f'CURRENT_PROJECT_VERSION = {number};', block)
                return block + match[2]
            text, count = re.subn(pattern, update, text, count=1, flags=re.DOTALL)
            if count != 1:
                raise ValueError(f'Cannot update app configuration {key}')
        elif str(settings['MARKETING_VERSION']) != marketing or str(settings['CURRENT_PROJECT_VERSION']) != number:
            raise ValueError('App versions differ; run --sync-app-version')
    if sync:
        project.write_text(text)
    notes_version = capture('RELEASE_NOTES.md', r'^# cghostty ([^\s]+)')
    if notes_version != version:
        raise ValueError(f'Release notes {notes_version} do not match app {version}')
    if tag is not None and tag != f'v{version}':
        raise ValueError(f'Release tag {tag} does not match v{version}')
    if app is not None:
        with (app / 'Contents/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        expected = {'CGhosttyVersion': version, 'CFBundleShortVersionString': marketing, 'CFBundleVersion': number}
        for key, value in expected.items():
            if str(info.get(key)) != value:
                raise ValueError(f'Bundle {key}={info.get(key)} does not match {value}')
    return version, number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--zig-version", action="store_true")
    output.add_argument("--zig-sha256", action="store_true")
    output.add_argument("--update-docs", action="store_true", help="refresh only the generated dependency table")
    output.add_argument('--sync-app-version', action='store_true', help='sync app configurations from build.zig.zon')
    parser.add_argument('--build-number', type=int, help='set all app build numbers with --sync-app-version')
    parser.add_argument('--tag', help='verify the release tag matches the app version')
    parser.add_argument('--app', type=Path, help='verify a built app matches the repository release')
    args = parser.parse_args()
    if args.build_number is not None and not args.sync_app_version:
        parser.error('--build-number requires --sync-app-version')
    try:
        toolchain, _ = check_versions()
        # Toolchain installation must remain possible while editing dependency docs.
        if not (args.zig_version or args.zig_sha256):
            check_dependency_docs(dependency_table(), update=args.update_docs)
            check_app_version(sync=args.sync_app_version, build_number=args.build_number, tag=args.tag, app=args.app)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Version check failed: {error}\n")
    if args.zig_version:
        print(toolchain["version"])
    elif args.zig_sha256:
        print(toolchain["sha256"])
    else:
        print(f"PASS: Zig {toolchain['version']}, dependencies, app versions and release notes")


if __name__ == "__main__":
    main()
