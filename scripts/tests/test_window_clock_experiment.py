import importlib.util
from pathlib import Path
import unittest
import json
import tempfile

spec = importlib.util.spec_from_file_location('clock_summary', Path(__file__).resolve().parents[1] / 'summarize-window-clock-experiment.py')
clock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clock)


class WindowClockExperimentTests(unittest.TestCase):
    def test_idle_gaps_and_other_windows_are_not_dropped_frames(self):
        rows = []
        for sequence, when, window, shown in [(1, 0, 1, 25_000_000), (2, 8_000_000, 1, 33_000_000),
                                              (3, 1_000_000_000, 1, 1_025_000_000), (4, 0, 2, 40_000_000)]:
            rows += [('clock_callback', 0, when, sequence, window),
                     ('clock_target', 0, when + 8_000_000, 8_000_000, sequence),
                     ('present_submit', 0, when + 100_000, sequence, 0),
                     ('displayed', 0, shown, sequence, 0)]
        rows.append(('clock_state', 0, 16_000_000, 1, 1))
        result = clock.clock_metrics(rows)
        self.assertEqual(result['continuous_display_interval_ms']['count'], 1)
        self.assertEqual(result['continuous_display_interval_ms']['median'], 8)
        self.assertEqual(result['long_display_interval_ratio'], 0)
        self.assertEqual(result['callbacks'], 4)

    def test_missing_callbacks_nil_and_unpresented_frames_are_separate(self):
        result = clock.clock_metrics([('present_submit', 0, 10, 1, 0),
                                      ('present_submit', 0, 20, 2, 0),
                                      ('displayed', 0, 0, 1, 0),
                                      ('drawable_acquire', 0, 1_000_000, 3, 1),
                                      ('clock_skip', 0, 100, 4, 1)])
        self.assertEqual(result['displayed_zero'], 1)
        self.assertEqual(result['submitted_without_callback'], 1)
        self.assertEqual(result['drawable_nil'], 1)
        self.assertEqual(result['skipped_busy'], 1)
        self.assertIsNone(result['callback_to_display_ms'])

    def test_prediction_error_and_phase_boundaries_do_not_mix_sessions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'trace').mkdir()
            (root / 'result.json').write_text(json.dumps({'phases': [{'id': 1}]}))
            (root / 'trace/render-a.csv').write_text(
                'experiment_phase,100,1,1,1\nmetal_tick,110,1,25000000,1\n'
                'displayed,120,24000000,1,0\nexperiment_phase,200,2,1,0\n')
            (root / 'trace/render-b.csv').write_text('displayed,300,90000000,2,0\n')
            result = clock.summarize(root)
            phase = result['phases'][0]
            self.assertEqual(phase['render']['surfaces'], 1)
            self.assertEqual(phase['clock']['prediction_absolute_error_ms']['median'], 1)
            self.assertEqual(phase['clock']['prediction_absolute_error_ms']['count'], 1)
