"""Exercise stale core and release mismatch rejection without building the app."""
import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import re
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CoreReuseTests(unittest.TestCase):
    def test_rejects_mode_version_sources_and_archive_changes(self):
        module = load('core-build-record')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('build.zig', 'build.zig.zon', 'scripts/zig-toolchain.json', 'scripts/core-build-record.py', 'src/main.zig'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name)
            archive = root / 'core.a'
            archive.write_bytes(b'original core')
            def run(mode, optimize='Debug', version='0.1.9'):
                argv = ['', mode, '--archive', str(archive), '--optimize', optimize, '--version', version]
                with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    module.main()
            with patch.object(module, 'ROOT', root), patch.object(module, 'environment', return_value={'zig': 'test', 'sdk': 'test'}):
                with self.assertRaises(SystemExit):
                    run('check')  # Archives built without a record are not trusted.
                run('record')
                run('check')
                for kwargs in ({'optimize': 'ReleaseFast'}, {'version': '0.1.10'}):
                    with self.assertRaises(SystemExit):
                        run('check', **kwargs)
                # Human-only guidance does not invalidate the core, while
                # embedded Markdown remains a tracked build input.
                (root / 'src/README.md').write_text('updated guide')
                (root / 'src/AGENTS.md').write_text('agent instructions')
                run('check')
                (root / 'src/help.md').write_text('embedded documentation')
                with self.assertRaises(SystemExit):
                    run('check')
                run('record')
                (root / 'src/main.zig').write_text('changed source')
                with self.assertRaises(SystemExit):
                    run('check')
                run('record')
                archive.write_bytes(b'replaced core')
                with self.assertRaises(SystemExit):
                    run('check')
                run('record')
                (root / 'src/new.zig').write_text('new input')
                with self.assertRaises(SystemExit):
                    run('check')
                run('record')
                (root / 'src/new.zig').unlink()
                with self.assertRaises(SystemExit):
                    run('check')


class ReleaseVersionTests(unittest.TestCase):
    def test_sync_targets_and_reject_stale_notes_tag_and_bundle(self):
        module = load('check-versions')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('build.zig.zon', 'RELEASE_NOTES.md', 'macos/Ghostty.xcodeproj/project.pbxproj'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, path)
            with patch.object(module, 'ROOT', root):
                version, number = module.check_app_version()
                marketing = re.split(r'[-+]', version)[0]
                module.check_app_version(tag=f'v{version}')
                with self.assertRaises(ValueError):
                    module.check_app_version(tag='v99.99.99')
                project = root / 'macos/Ghostty.xcodeproj/project.pbxproj'
                original = project.read_text()
                project.write_text(original.replace(f'MARKETING_VERSION = {marketing};', 'MARKETING_VERSION = 99.99.99;'))
                with self.assertRaises(ValueError):
                    module.check_app_version()
                module.check_app_version(sync=True)
                self.assertEqual(project.read_text(), original)
                module.check_app_version(sync=True, build_number=int(number) + 1)
                self.assertEqual(module.check_app_version()[1], str(int(number) + 1))
                self.assertEqual(project.read_text().count('CURRENT_PROJECT_VERSION = 1;'), original.count('CURRENT_PROJECT_VERSION = 1;'))
                bundle = root / 'test.app'
                (bundle / 'Contents').mkdir(parents=True)
                info = {'CGhosttyVersion': version, 'CFBundleShortVersionString': marketing, 'CFBundleVersion': str(int(number) + 1)}
                path = bundle / 'Contents/Info.plist'
                path.write_bytes(plistlib.dumps(info))
                module.check_app_version(app=bundle)
                info['CGhosttyVersion'] = '99.99.99'
                path.write_bytes(plistlib.dumps(info))
                with self.assertRaises(ValueError):
                    module.check_app_version(app=bundle)
                (root / 'RELEASE_NOTES.md').write_text('# cghostty 99.99.99\n')
                with self.assertRaises(ValueError):
                    module.check_app_version()


if __name__ == '__main__':
    unittest.main()
