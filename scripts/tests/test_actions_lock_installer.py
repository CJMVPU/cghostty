"""Verify the lockfile tool cannot be published before download integrity checks."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ActionsLockInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='actions-lock-工具-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = self.root / 'install-actions-lock.sh'
        shutil.copyfile(ROOT / 'scripts/install-actions-lock.sh', self.script)
        self.payload = b'#!/bin/sh\necho "must not execute during installation"\n'
        (self.root / 'payload').write_bytes(self.payload)
        self.record = self.root / 'actions-lock-toolchain.json'
        self.record.write_text(json.dumps({'version': '0.2.0', 'sha256': hashlib.sha256(self.payload).hexdigest()}))
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], FIXTURE_ROOT=str(self.root))
        commands = {
            'uname': 'if [[ "$1" == -s ]]; then echo Darwin; else echo "${TEST_MACHINE:-arm64}"; fi',
            'curl': '''
echo call >> "$FIXTURE_ROOT/curl-calls"
[[ "${FAIL_DOWNLOAD:-}" != 1 ]] || exit 22
while [[ "$1" != --output ]]; do shift; done
cp "$FIXTURE_ROOT/payload" "$2"
''',
        }
        for name, body in commands.items():
            path = bin_dir / name
            path.write_text('#!/bin/bash\nset -euo pipefail\n' + body + '\n')
            path.chmod(0o755)
        self.destination = self.root / 'tools with spaces'
        self.binary = self.destination / 'gh-actions-lock-0.2.0/gh-actions-lock'

    def install(self):
        return subprocess.run(['bash', str(self.script), str(self.destination)], env=self.env, text=True, capture_output=True)

    def test_verified_download_is_reused_and_tampered_cache_is_replaced(self):
        for expected_calls in [1, 1, 2]:
            if expected_calls == 2:
                self.binary.write_bytes(b'tampered cache')
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(self.binary))
            self.assertEqual(self.binary.read_bytes(), self.payload)
            self.assertTrue(os.access(self.binary, os.X_OK))
            self.assertEqual(len((self.root / 'curl-calls').read_text().splitlines()), expected_calls)

    def test_bad_download_never_replaces_existing_binary_or_leaves_temporary_files(self):
        self.binary.parent.mkdir(parents=True)
        original = b'old binary'
        self.binary.write_bytes(original)
        for failure in ['checksum', 'network']:
            with self.subTest(failure=failure):
                (self.root / 'payload').write_bytes(b'corrupt download')
                self.env['FAIL_DOWNLOAD'] = '1' if failure == 'network' else '0'
                self.assertNotEqual(self.install().returncode, 0)
                self.assertEqual(self.binary.read_bytes(), original)
                self.assertEqual(list(self.binary.parent.glob('.download.*')), [])

    def test_invalid_record_and_unsupported_machine_stop_before_download(self):
        self.env['TEST_MACHINE'] = 'x86_64'
        self.assertNotEqual(self.install().returncode, 0)
        self.env['TEST_MACHINE'] = 'arm64'
        self.record.write_text(json.dumps({'version': '../main', 'sha256': 'bad'}))
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((self.root / 'curl-calls').exists())
        self.assertFalse(self.binary.exists())
