#!/usr/bin/env python3
"""Print a build environment report, including unavailable tools after setup failures."""

import os
import shlex
import subprocess


def main():
    print("# Build environment\n")
    # Only public runner metadata; never dump the full environment.
    for key in ("GITHUB_SHA", "RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion"):
        if value := os.environ.get(key):
            print(f"- {key}: {value}")

    commands = (
        ("macOS", ["sw_vers"]),
        ("Architecture", ["uname", "-m"]),
        ("Developer directory", ["xcode-select", "-p"]),
        ("Xcode", ["xcodebuild", "-version"]),
        ("macOS SDK", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        ("macOS SDK build", ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
        ("Swift", ["xcrun", "swift", "--version"]),
        ("Metal", ["xcrun", "--toolchain", "Metal", "metal", "--version"]),
        ("Zig", ["zig", "version"]),
        ("Nushell", ["nu", "--version"]),
        ("SwiftLint", ["swiftlint", "version"]),
        ("actionlint", ["actionlint", "--version"]),
        ("Python", ["python3", "--version"]),
    )
    for label, command in commands:
        print(f"\n## {label}\n\n```text\n$ {shlex.join(command)}", flush=True)
        try:
            result = subprocess.run(
                command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, timeout=30, check=False,
            )
            print(result.stdout.rstrip())
            if result.returncode:
                print(f"Unavailable: command exited with status {result.returncode}")
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"Unavailable: {error}")
        print("```")


if __name__ == "__main__":
    main()
