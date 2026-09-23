import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'build-cache.py'
spec = importlib.util.spec_from_file_location('build_cache', SCRIPT)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class BuildCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.retained = {}
        for name in ('.zig-cache/o/old/object.o', 'src/main.zig',
                     'zig-pkg/dependency/source.zig', 'zig-out/lib/core.a',
                     'macos/build/ReleaseLocal/cghostty.app/Contents/MacOS/cghostty',
                     'macos/build/TestResults.xcresult/Info.plist', 'artifacts/release.zip'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
            if not name.startswith('.zig-cache/'):
                self.retained[path] = name

    def run_maintenance(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return cache.maintain(self.root, **kwargs)

    def test_report_and_under_threshold_never_delete(self):
        with patch.object(cache, 'active_builds', side_effect=AssertionError('Must not query processes')):
            self.assertFalse(self.run_maintenance())
            self.assertFalse(self.run_maintenance(trim=True))
        self.assertTrue((self.root / '.zig-cache/o/old/object.o').exists())

    def test_trim_removes_only_cache_and_is_repeatable(self):
        outside = self.root / 'important.txt'
        outside.write_text('keep')
        (self.root / '.zig-cache/external-link').symlink_to(outside)
        with patch.object(cache, 'active_builds', return_value=set()):
            self.assertTrue(self.run_maintenance(trim=True, max_bytes=1))
            self.assertFalse(self.run_maintenance(clear=True))
        self.assertFalse((self.root / '.zig-cache').exists())
        for path, original in self.retained.items():
            self.assertEqual(path.read_text(), original)
        self.assertEqual(outside.read_text(), 'keep')

    def test_running_build_or_unknown_process_state_skips_cleanup(self):
        with patch.object(cache, 'active_builds', return_value={'zig'}):
            self.assertFalse(self.run_maintenance(clear=True))
        with patch.object(cache, 'active_builds', side_effect=subprocess.CalledProcessError(1, 'ps')):
            self.assertFalse(self.run_maintenance(clear=True))
        self.assertTrue((self.root / '.zig-cache/o/old/object.o').exists())

    def test_symlink_cache_is_rejected(self):
        (self.root / '.zig-cache').rename(self.root / 'external-cache')
        (self.root / '.zig-cache').symlink_to(self.root / 'external-cache', target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.run_maintenance(clear=True)
        self.assertTrue((self.root / 'external-cache/o/old/object.o').exists())

    def test_tracked_cache_is_rejected(self):
        subprocess.run(['git', '-C', str(self.root), 'add', '.zig-cache'], check=True)
        with self.assertRaisesRegex(ValueError, 'tracked'):
            self.run_maintenance(clear=True)
        self.assertTrue((self.root / '.zig-cache/o/old/object.o').exists())


if __name__ == '__main__':
    unittest.main()
