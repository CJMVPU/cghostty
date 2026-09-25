"""Exercise the actual shell integrations with a harmless Claude executable."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
INTEGRATION = ROOT / 'src/shell-integration'


class ClaudeCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='cghostty-claude-')
        self.addCleanup(self.directory.cleanup)
        self.temp = Path(self.directory.name)
        self.result = self.temp / 'result.json'
        stub = self.temp / 'claude'
        stub.write_text(
            '#!' + sys.executable + '\n'
            'import json, os, sys\n'
            'from pathlib import Path\n'
            'Path(os.environ["CGHOSTTY_COMPAT_TEST_RESULT"]).write_text(json.dumps({\n'
            ' "terminal": os.environ.get("TERM_PROGRAM"),\n'
            ' "version": os.environ.get("TERM_PROGRAM_VERSION"),\n'
            ' "arguments": sys.argv[1:]\n'
            '}))\n'
            'sys.exit(17)\n'
        )
        stub.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.temp) + ':' + self.env['PATH'],
                        TERM_PROGRAM='cghostty', TERM_PROGRAM_VERSION='0.3.0',
                        GHOSTTY_SHELL_FEATURES='',
                        CGHOSTTY_COMPAT_TEST_RESULT=str(self.result))
        for name in ('GHOSTTY_BASH_INJECT', 'CGHOSTTY_CLAUDE_COMPATIBILITY'):
            self.env.pop(name, None)

    def run_shell(self, shell, enabled, existing=False):
        executable = shutil.which(shell)
        if not executable:
            self.skipTest(f'{shell} is not installed')
        if enabled:
            self.env['CGHOSTTY_CLAUDE_COMPATIBILITY'] = '1'
        if shell in ('zsh', 'bash'):
            resource = (INTEGRATION / 'zsh/ghostty-integration' if shell == 'zsh'
                        else INTEGRATION / 'bash/ghostty.bash')
            source = 'source ' + shlex.quote(str(resource)) + '\n'
            if shell == 'zsh':
                source += '_ghostty_deferred_init\n'
            prefix = 'claude() { command claude preserved "$@"; }\n' if existing else ''
            script = prefix + source + (
                'claude "a b" --resume ""\n'
                'compat_status=$?\n'
                '[ "$TERM_PROGRAM" = cghostty ] && [ "$TERM_PROGRAM_VERSION" = 0.3.0 ] || exit 90\n'
                'exit "$compat_status"\n'
            )
            flags = ['-d', '-f', '-i', '-c'] if shell == 'zsh' else ['--noprofile', '--norc', '-i', '-c']
        elif shell == 'nu':
            resource = INTEGRATION / 'nushell/vendor/autoload/ghostty.nu'
            script = (
                'source ' + json.dumps(str(resource)) + '\nuse ghostty *\n'
                'claude "a b" --resume ""\nlet compat_status = $env.LAST_EXIT_CODE\n'
                'if $env.TERM_PROGRAM != "cghostty" or $env.TERM_PROGRAM_VERSION != "0.3.0" { exit 90 }\n'
                'exit $compat_status\n'
            )
            flags = ['--no-config-file', '-c']
        else:
            resource = INTEGRATION / 'fish/vendor_conf.d/ghostty-shell-integration.fish'
            script = (
                'source ' + shlex.quote(str(resource)) + '\n__ghostty_setup\n'
                'claude "a b" --resume ""\nset compat_status $status\n'
                'test "$TERM_PROGRAM" = cghostty; and test "$TERM_PROGRAM_VERSION" = 0.3.0; or exit 90\n'
                'exit $compat_status\n'
            )
            flags = ['--no-config', '-i', '-c']
        result = subprocess.run([executable, *flags, script], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(json.loads(self.result.read_text()), {
            'terminal': 'ghostty' if enabled and not existing else 'cghostty',
            'version': '1.2.0' if enabled and not existing else '0.3.0',
            'arguments': (['preserved'] if existing else []) + ['a b', '--resume', ''],
        })

    def test_zsh_enabled(self):
        self.run_shell('zsh', True)

    def test_zsh_disabled(self):
        self.run_shell('zsh', False)

    def test_zsh_preserves_existing_function(self):
        self.run_shell('zsh', True, existing=True)

    def test_bash_enabled(self):
        self.run_shell('bash', True)

    def test_bash_disabled(self):
        self.run_shell('bash', False)

    def test_bash_preserves_existing_function(self):
        self.run_shell('bash', True, existing=True)

    def test_nushell_enabled(self):
        self.run_shell('nu', True)

    def test_nushell_disabled(self):
        self.run_shell('nu', False)

    def test_fish_enabled(self):
        self.run_shell('fish', True)

    def test_fish_disabled(self):
        self.run_shell('fish', False)


if __name__ == '__main__':
    unittest.main()
