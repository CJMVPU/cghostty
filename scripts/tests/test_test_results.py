import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'test-results.py'
spec = importlib.util.spec_from_file_location('test_results', SCRIPT)
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)


class TestResultRetentionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def bundle(self, number, status):
        path = self.root / f'run-{number:04d}-{"a" * 32}.xcresult'
        path.mkdir()
        (path / 'attachment').write_bytes(b'x' * 8192)
        path.with_suffix('.json').write_text(json.dumps({'result': status, 'passedTests': 1 if status == 'Passed' else 0}))
        return path

    def test_keeps_latest_success_and_two_failures_with_summaries(self):
        bundles = [self.bundle(i, status) for i, status in enumerate(
            ['Passed', 'Failed', 'Failed', 'Failed', 'Passed'])]
        results.maintain(self.root)
        self.assertEqual([p.exists() for p in bundles], [False, False, True, True, True])
        self.assertTrue(all(p.with_suffix('.json').exists() for p in bundles))

    def test_capacity_can_drop_large_bundle_but_preserves_summary(self):
        bundle = self.bundle(1, 'Failed')
        results.maintain(self.root, max_bytes=1)
        self.assertFalse(bundle.exists())
        self.assertTrue(bundle.with_suffix('.json').exists())

    def test_only_owns_generated_names_and_never_follows_symlinks(self):
        user = self.root / 'UserResults.xcresult'
        user.mkdir()
        (user / 'keep').write_text('keep')
        link = self.root / f'run-0001-{"b" * 32}.xcresult'
        link.symlink_to(user, target_is_directory=True)
        results.maintain(self.root, max_bytes=1)
        self.assertTrue(link.is_symlink())
        self.assertEqual((user / 'keep').read_text(), 'keep')

    def test_explicit_paths_are_untouched(self):
        for args in [[], ['--action', 'build'], ['--action', 'test', '--result-bundle', 'mine']]:
            forwarded, directory = results.prepare(self.root, args)
            self.assertEqual(forwarded, args)
            self.assertIsNone(directory)

    def test_default_test_destination_reuses_checkout_directory(self):
        with patch.dict(results.os.environ, {'TMPDIR': str(self.root)}):
            args = ['--action', 'test', '--result-bundle', '']
            first, directory = results.prepare(self.root, args)
            second, again = results.prepare(self.root, args)
        self.assertEqual(directory, again)
        self.assertNotEqual(first[-1], second[-1])
        self.assertEqual(Path(first[-1]).parent, directory)

    def test_extracts_summary_before_removing_bundle(self):
        bundle = self.bundle(1, 'Failed')
        bundle.with_suffix('.json').unlink()
        with patch.object(results.subprocess, 'check_output', return_value='{"result":"Failed","failedTests":2}'):
            results.maintain(self.root, max_bytes=1)
        self.assertEqual(json.loads(bundle.with_suffix('.json').read_text())['failedTests'], 2)

    def test_summary_history_is_bounded(self):
        for i in range(25):
            self.bundle(i, 'Passed')
        results.maintain(self.root)
        self.assertEqual(len(list(self.root.glob('*.json'))), 20)
        self.assertEqual(len(list(self.root.glob('*.xcresult'))), 1)

    def test_large_failure_transcripts_do_not_make_unbounded_summaries(self):
        bundle = self.bundle(1, 'Failed')
        bundle.with_suffix('.json').unlink()
        output = json.dumps({'result': 'Failed', 'testFailures': [{'message': 'x' * 10000}] * 100})
        with patch.object(results.subprocess, 'check_output', return_value=output):
            data = results.summary(bundle)
        self.assertEqual(data['omittedFailureDetails'], 80)
        self.assertLess(bundle.with_suffix('.json').stat().st_size, 64 * 1024)

    def test_repeated_selections_are_forwarded_together(self):
        args = ['--action', 'test', '--only-testing', 'GhosttyTests/SettingsTests',
                '--skip-core', '--only-testing', 'GhosttyTests/ConfigTests']
        normalized = results.normalize_selections(args)
        self.assertEqual(results.selections(normalized), ['GhosttyTests/SettingsTests', 'GhosttyTests/ConfigTests'])
        self.assertEqual(normalized.count('--only-testing'), 1)
        self.assertIn('--skip-core', normalized)
        with self.assertRaises(ValueError):
            results.normalize_selections(['--only-testing', '--skip-core'])

    def test_zero_tests_and_all_skipped_cannot_pass(self):
        for data in [{'result': 'Passed', 'passedTests': 0},
                     {'result': 'Passed', 'passedTests': 0, 'skippedTests': 2},
                     {'result': 'Incomplete'}, {'result': 'Failed', 'passedTests': 1, 'failedTests': 1}]:
            with patch.object(results, 'summary', return_value=data):
                with self.assertRaises(ValueError):
                    results.verify(self.root / 'test.xcresult')
        with patch.object(results, 'summary', return_value={'result': 'Passed', 'passedTests': 2}):
            results.verify(self.root / 'test.xcresult')

    def test_custom_build_directory_also_gets_a_verifiable_bundle(self):
        args, directory = results.prepare(self.root, ['--action', 'test', '--build-dir', str(self.root)])
        self.assertIsNone(directory)
        self.assertEqual(Path(results.option(args, '--result-bundle')).parent, self.root.resolve())

    def test_one_missing_selection_fails_even_when_other_tests_pass(self):
        tree = {'testNodes': [{'nodeType': 'Unit test bundle', 'name': 'GhosttyTests', 'children': [
            {'nodeType': 'Test Case', 'nodeIdentifier': 'SettingsTests/save()', 'result': 'Passed'},
            {'nodeType': 'Test Case', 'nodeIdentifier': 'SettingsTests/skipped()', 'result': 'Skipped'}]}]}
        with patch.object(results, 'summary', return_value={'result': 'Passed', 'passedTests': 1}), \
                patch.object(results.subprocess, 'check_output', return_value=json.dumps(tree)):
            results.verify(self.root / 'test.xcresult', ['GhosttyTests/SettingsTests'])
            with self.assertRaisesRegex(ValueError, 'No tests executed'):
                results.verify(self.root / 'test.xcresult', ['GhosttyTests/SettingsTests', 'GhosttyTests/Missing'])
            with self.assertRaisesRegex(ValueError, 'No tests executed'):
                results.verify(self.root / 'test.xcresult', ['GhosttyTests/SettingsTests/skipped()'])

    def test_zero_run_does_not_replace_last_success_in_retention(self):
        good = self.bundle(1, 'Passed')
        zero = self.bundle(2, 'Passed')
        zero.with_suffix('.json').write_text(json.dumps({'result': 'Passed', 'passedTests': 0}))
        results.maintain(self.root)
        self.assertTrue(good.exists())
        self.assertTrue(zero.exists())

    def test_xctest_method_selection_matches_result_parentheses(self):
        tree = {'testNodes': [{'nodeType': 'UI test bundle', 'name': 'GhosttyUITests', 'children': [
            {'nodeType': 'Test Case', 'nodeIdentifier': 'SettingsTests/testSave()', 'result': 'Passed'}]}]}
        with patch.object(results, 'summary', return_value={'result': 'Passed', 'passedTests': 1}), \
                patch.object(results.subprocess, 'check_output', return_value=json.dumps(tree)):
            results.verify(self.root / 'test.xcresult', ['GhosttyUITests/SettingsTests/testSave'])
            results.verify(self.root / 'test.xcresult', ['GhosttyUITests/SettingsTests/testSave()'])
            with self.assertRaisesRegex(ValueError, 'No tests executed'):
                results.verify(self.root / 'test.xcresult', ['GhosttyUITests/SettingsTests/testSav'])
