"""Run +ssh against a local process double, never a network host."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = os.environ.get('CGHOSTTY_TEST_BINARY')


@unittest.skipUnless(BINARY, 'set CGHOSTTY_TEST_BINARY to a built cghostty executable')
class SshCliTests(unittest.TestCase):
    def test_environment_and_installer(self):
        for forward, install, fail, expected in (
            (True, False, False, 'xterm-256color'),
            (False, False, False, 'test-inherited-term'),
            (False, True, False, 'xterm-ghostty'),
            (True, True, False, 'xterm-ghostty'),
            (False, True, True, 'xterm-256color'),
        ):
            with self.subTest(forward=forward, install=install, fail=fail), tempfile.TemporaryDirectory() as directory:
                record = Path(directory) / 'calls.jsonl'
                fake = Path(directory) / 'ssh'
                fake.write_text(f'#!{sys.executable}\n' + '''import json,os,sys
args = sys.argv[1:]
if "-G" in args:
    print("hostname example.invalid\\nuser regression")
    sys.exit(0)
installer = any(a.startswith("sh -c ") for a in args)
payload = sys.stdin.buffer.read() if installer else b""
with open(os.environ["CGHOSTTY_SSH_TEST_RECORD"], "a") as output:
    output.write(json.dumps(dict(args=args, term=os.environ.get("TERM"), installer=installer, bytes=len(payload))) + "\\n")
if installer:
    print("SSH-AUTH-TEST", file=sys.stderr)
    sys.exit(int(os.environ["CGHOSTTY_SSH_TEST_FAIL"]))
''')
                fake.chmod(0o755)
                env = os.environ.copy()
                env.update(TERM='test-inherited-term', CGHOSTTY_SSH_TEST_RECORD=str(record),
                           CGHOSTTY_SSH_TEST_FAIL=str(int(fail)))
                result = subprocess.run([
                    BINARY, '+ssh', f'--ssh={fake}', '--cache=false',
                    f'--forward-env={str(forward).lower()}', f'--terminfo={str(install).lower()}',
                    '--', '-o', 'SetEnv=EDITOR=vim', 'example.invalid',
                ], env=env, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
                calls = [json.loads(line) for line in record.read_text().splitlines()]
                session = calls[-1]
                self.assertFalse(session['installer'])
                self.assertEqual(session['term'], expected)
                self.assertIn('SetEnv=EDITOR=vim', session['args'])
                self.assertFalse(any('SetEnv=TERM=' in arg for arg in session['args']))
                self.assertEqual('SendEnv=COLORTERM' in session['args'], forward)
                if install:
                    setup = calls[0]
                    self.assertTrue(setup['installer'])
                    self.assertGreater(setup['bytes'], 0)
                    command = setup['args'][-1]
                    self.assertIn('tic -x -o ~/.terminfo -', command)
                    self.assertIn('infocmp -x xterm-ghostty', command)
                    self.assertIn(b'SSH-AUTH-TEST', result.stderr)


if __name__ == '__main__':
    unittest.main()
