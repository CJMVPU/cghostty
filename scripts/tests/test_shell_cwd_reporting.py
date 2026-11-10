"""Exercise actual shell reporting code with hostile directory names."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ShellCwdReportingTests(unittest.TestCase):
    def test_zsh_reports_paths_without_interpreting_escapes(self):
        source = (ROOT / 'src/shell-integration/zsh/ghostty-integration').read_text()
        match = re.search(r'    _ghostty_report_pwd\(\) \{\n.*?\n    \}', source, re.S)
        self.assertIsNotNone(match)
        self.check_reporting('/bin/zsh', '_ghostty_fd=1\n' + match[0] + '\n_ghostty_report_pwd')

    def test_bash_reports_paths_without_control_sequences(self):
        source = (ROOT / 'src/shell-integration/bash/ghostty.bash').read_text()
        line = next(line for line in source.splitlines() if 'builtin printf' in line and 'kitty-shell-cwd://' in line)
        self.check_reporting('/bin/bash', line)

    def check_reporting(self, shell, script):
        for name in ('中文 normal', r'x\a\e]52;c;SGVsbG8=\a', 'x\x07\x1b]52;c;SGVsbG8=\x07'):
            with self.subTest(shell=shell, name=name), tempfile.TemporaryDirectory() as directory:
                cwd = Path(directory) / name
                cwd.mkdir()
                result = subprocess.run([shell, '-c', script], cwd=cwd, capture_output=True, check=True)
                output = result.stdout
                self.assertTrue(output.startswith(b'\x1b]7;kitty-shell-cwd://'))
                self.assertEqual(output.count(b'\x1b'), 1)
                self.assertEqual(output.count(b'\x07'), 1)
                safe_name = ''.join(c for c in name if ord(c) >= 32 and ord(c) != 127)
                self.assertTrue(output.endswith(safe_name.encode() + b'\x07'), output)


if __name__ == '__main__':
    unittest.main()
