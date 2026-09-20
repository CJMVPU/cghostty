#!/usr/bin/env python3
"""Keep every native target and configuration on the checked Swift 6 baseline."""

import argparse
import json
from pathlib import Path
import subprocess


def check_project(path):
    project = json.loads(subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(path)], text=True
    ))
    objects = project["objects"]
    root = objects[project["rootObject"]]

    def configurations(owner):
        return [objects[key] for key in
                objects[owner["buildConfigurationList"]]["buildConfigurations"]]

    project_settings = {config["name"]: config["buildSettings"]
                        for config in configurations(root)}
    count = 0
    for target_id in root["targets"]:
        target = objects[target_id]
        for config in configurations(target):
            label = f"{target['name']} / {config['name']}"
            settings = project_settings[config["name"]] | config["buildSettings"]
            required = {
                "SWIFT_VERSION": "6.0",
                "SWIFT_STRICT_CONCURRENCY": "complete",
                "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
            }
            if target["name"] in {"Ghostty", "GhosttyTests"}:
                required |= {
                    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
                    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
                }
            for key, value in required.items():
                if settings.get(key) != value:
                    raise ValueError(f"{label}: {key} must be {value}")
            count += 1
    if count == 0:
        raise ValueError("No native build configurations found")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1]
                        / "macos/Ghostty.xcodeproj/project.pbxproj")
    args = parser.parse_args()
    try:
        count = check_project(args.project)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Swift 6 check failed: {error}\n")
    print(f"PASS: Swift 6, complete concurrency checks and warnings as errors in {count} configurations")


if __name__ == "__main__":
    main()
