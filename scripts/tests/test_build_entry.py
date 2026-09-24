import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'build.py'
spec = importlib.util.spec_from_file_location('managed_build', SCRIPT)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildEntryTests(unittest.TestCase):
    def setUp(self):
        preflight = patch.object(build.toolchain, 'check')
        self.preflight = preflight.start()
        self.addCleanup(preflight.stop)

    def test_modes_forward_arguments_and_preserve_failure_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(build, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                for mode, arguments, expected in (
                    ('test', ['-Dtest-filter=terminal.'], ['zig', 'build', 'test', '-Demit-macos-app=false', '-Dtest-filter=terminal.']),
                    ('core', ['-Doptimize=ReleaseFast'], ['zig', 'build', '-Demit-macos-app=false', '-Doptimize=ReleaseFast']),
                    ('native', ['--action', 'test'], ['nu', str(root / 'macos/build.nu'), '--action', 'test']),
                ):
                    with patch.object(build.subprocess, 'run') as run, patch.object(
                            build.results, 'prepare', return_value=(arguments, None)):
                        run.return_value.returncode = 7
                        self.assertEqual(build.run(mode, arguments), 7)
                        self.assertEqual(run.call_args.args[0], expected)
                        self.assertEqual(run.call_args.kwargs['env']['CGHOSTTY_BUILD_LOCK_ROOT'], str(root))

    def test_native_clean_does_not_trim(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(build.cache, 'maintain_locked') as trim:
            with patch.object(build, 'ROOT', Path(directory)), patch.object(build.subprocess, 'run'):
                build.run('native', ['--action', 'clean'])
            trim.assert_not_called()
            self.preflight.assert_not_called()

    def test_invalid_toolchain_stops_before_cache_or_build_changes(self):
        self.preflight.side_effect = ValueError('Incomplete Zig installation')
        with patch.object(build.cache, 'maintain_locked') as trim, patch.object(build.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Incomplete Zig'):
                build.run('core', [])
            trim.assert_not_called()
            run.assert_not_called()
