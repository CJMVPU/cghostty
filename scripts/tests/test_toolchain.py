import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'check-toolchain.py'
spec = importlib.util.spec_from_file_location('toolchain_check', SCRIPT)
toolchain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(toolchain)
VERSION = json.loads((SCRIPT.parent / 'zig-toolchain.json').read_text())['version']


class ToolchainTests(unittest.TestCase):
    def test_missing_executable(self):
        with patch.object(toolchain.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(ValueError, 'not on PATH'):
                toolchain.check()

    def test_wrong_version_stops_before_env(self):
        with patch.object(toolchain.shutil, 'which', return_value='/zig'), \
                patch.object(toolchain.subprocess, 'check_output', return_value='0.15.0'), \
                patch.object(toolchain.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Expected Zig'):
                toolchain.check()
            run.assert_not_called()

    def test_incomplete_and_complete_library(self):
        with tempfile.TemporaryDirectory(prefix='cghostty-工具-') as directory:
            library = Path(directory)
            (library / 'std').mkdir()
            (library / 'std/std.zig').touch()
            quoted = '"' + ''.join(
                chr(byte) if 32 <= byte < 127 and byte not in (34, 92) else f'\\x{byte:02x}'
                for byte in directory.encode('utf-8')
            ) + '"'
            output = f'.{{\n .lib_dir = {quoted},\n}}'
            with patch.object(toolchain.shutil, 'which', return_value='/zig'), \
                    patch.object(toolchain.subprocess, 'check_output', return_value=VERSION), \
                    patch.object(toolchain.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output)):
                with self.assertRaisesRegex(ValueError, 'compiler/build_runner.zig'):
                    toolchain.check()
                (library / 'compiler').mkdir()
                (library / 'compiler/build_runner.zig').touch()
                toolchain.check()

    def test_env_failure_is_actionable(self):
        with patch.object(toolchain.shutil, 'which', return_value='/zig'), \
                patch.object(toolchain.subprocess, 'check_output', return_value=VERSION), \
                patch.object(toolchain.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'missing lib')):
            with self.assertRaisesRegex(ValueError, 'Incomplete Zig installation.*install-zig.sh'):
                toolchain.check()
