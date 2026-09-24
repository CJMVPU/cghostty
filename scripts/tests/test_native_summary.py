import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'summarize-native-tests.py'
spec = importlib.util.spec_from_file_location('native_summary', SCRIPT)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class NativeSummaryTests(unittest.TestCase):
    def test_failure_text_and_nested_skips_are_visible(self):
        result = summary.render({
            'result': 'Failed', 'passedTests': 3, 'failedTests': 1, 'skippedTests': 1,
            'testFailures': [{'testIdentifierString': 'Frames/first()',
                              'failureText': 'No completed terminal frame\nrevision=0'}],
        }, {'testNodes': [{'nodeType': 'Test Suite', 'result': 'Skipped', 'children': [{
            'nodeType': 'Test Case', 'result': 'Skipped', 'nodeIdentifier': 'Frames/image()',
            'children': [{'nodeType': 'Skip Message', 'name': 'Requires Metal 4'}],
        }]}]}, {'devices': [{'name': 'Virtual GPU', 'metal4': False}]})
        self.assertIn('failed: 1; skipped: 1', result)
        self.assertIn('    No completed terminal frame\n    revision=0', result)
        self.assertEqual(result.count('Frames/image()'), 1)
        self.assertIn('Requires Metal 4', result)
        self.assertIn('not GPU rendering validation', result)
        self.assertIn('Virtual GPU', result)

    def test_success_without_gpu_report_or_skips(self):
        result = summary.render({'result': 'Passed', 'passedTests': 4, 'failedTests': 0, 'skippedTests': 0}, {}, None)
        self.assertIn('Result: Passed', result)
        self.assertNotIn('### Failure', result)
        self.assertNotIn('### Skipped', result)
        self.assertNotIn('### Runtime', result)
