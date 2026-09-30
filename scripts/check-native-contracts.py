#!/usr/bin/env python3
"""Run pure Swift bridge/input/transaction tests without launching the app."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    'macos/Sources/Ghostty/InputText.swift',
    'macos/Sources/Ghostty/CompositorResult.swift',
    'macos/Sources/Features/Terminal/WindowFrameTransaction.swift',
)
TESTS = (
    'macos/Tests/Ghostty/InputTextTests.swift',
    'macos/Tests/Ghostty/CompositorResultTests.swift',
    'macos/Tests/Terminal/WindowFrameTransactionTests.swift',
)


def main():
    with tempfile.TemporaryDirectory(prefix='cghostty-native-contracts-') as directory:
        package = Path(directory)
        source = package / 'Sources/NativeContracts'
        tests = package / 'Tests/NativeContractTests'
        bridge = package / 'Sources/GhosttyKit'
        for path in (source, tests, bridge):
            path.mkdir(parents=True)
        (package / 'Package.swift').write_text(
            '// swift-tools-version: 6.0\n'
            'import PackageDescription\n'
            'let package = Package(name: "NativeContracts", platforms: [.macOS("27.0")], targets: [\n'
            ' .systemLibrary(name: "GhosttyKit"),\n'
            ' .target(name: "NativeContracts", dependencies: ["GhosttyKit"], swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors"])]),\n'
            ' .testTarget(name: "NativeContractTests", dependencies: ["NativeContracts"], swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors"])])\n'
            '])\n')
        header = json.dumps(str(ROOT / 'include/ghostty.h'))
        (bridge / 'module.modulemap').write_text(
            f'module GhosttyKit [system] {{ header {header} export * }}\n')
        for path in SOURCES:
            (source / Path(path).name).symlink_to(ROOT / path)
        for path in TESTS:
            # Use the checked-in tests unchanged except for the test module.
            (tests / Path(path).name).write_text((ROOT / path).read_text().replace(
                '@testable import Ghostty', '@testable import NativeContracts'))
        env = os.environ.copy()
        env['CLANG_MODULE_CACHE_PATH'] = str(package / 'module-cache')
        env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(package / 'module-cache')
        command = ['swift', 'test', '--package-path', directory]
        for option, name in (('--cache-path', 'cache'), ('--config-path', 'config'),
                             ('--security-path', 'security'), ('--scratch-path', 'build')):
            command.extend((option, str(package / name)))
        result = subprocess.run(command, env=env)
        if result.returncode == 0:
            print('PASS: pure native contracts; AppKit/Metal integration not exercised')
        return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
