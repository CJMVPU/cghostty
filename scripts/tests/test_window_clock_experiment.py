import importlib.util
from pathlib import Path
import unittest
import json
import tempfile

spec = importlib.util.spec_from_file_location('clock_summary', Path(__file__).resolve().parents[1] / 'summarize-window-clock-experiment.py')
clock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clock)


class WindowClockExperimentTests(unittest.TestCase):
    def test_gpu_timeline_uses_first_enqueue_not_present_call(self):
        rows = [('window_enqueue', 0, 1_000_000, 7, 0),
                ('window_gpu_first', 80_000_000, 3_000_000, 4_000_000, 7),
                ('window_gpu_last', 70_000_000, 5_000_000, 6_000_000, 7),
                ('present_submit', 0, 5_500_000, 7, 0),
                ('displayed', 60_000_000, 20_000_000, 7, 0)]
        result = clock.gpu_timeline(rows)
        self.assertEqual(result['enqueue_to_gpu_start_ms']['median'], 2)
        self.assertEqual(result['gpu_window_span_ms']['median'], 3)
        self.assertEqual(result['gpu_end_to_display_ms']['median'], 14)
        self.assertEqual(result['enqueue_to_display_ms']['median'], 19)

    def test_gpu_timeline_counts_missing_zero_and_invalid_separately(self):
        rows = [('window_enqueue', 0, 10, seq, 0) for seq in range(1, 5)]
        for seq, start, shown in [(2, 20, 0), (3, 0, 60), (4, 9, 60)]:
            rows += [('window_gpu_first', 0, start, 30, seq),
                     ('window_gpu_last', 0, 40, 50, seq), ('displayed', 0, shown, seq, 0)]
        result = clock.gpu_timeline(rows)
        self.assertEqual(result['missing_timeline'], 1)
        self.assertEqual(result['unpresented_timeline'], 1)
        self.assertEqual(result['invalid_timeline'], 2)
        self.assertIsNone(result['gpu_window_span_ms'])

    def test_gpu_boundary_intervals_may_overlap(self):
        result = clock.gpu_timeline([('window_enqueue', 0, 10, 1, 0),
                                     ('window_gpu_first', 0, 20, 40, 1),
                                     ('window_gpu_last', 0, 39, 50, 1),
                                     ('displayed', 0, 60, 1, 0)])
        self.assertEqual(result['invalid_timeline'], 0)
        self.assertEqual(result['gpu_window_span_ms']['count'], 1)

    def test_gpu_feedback_after_phase_end_is_joined_by_frame(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'trace').mkdir()
            (root / 'result.json').write_text(json.dumps({'phases': [{'id': 1}]}))
            (root / 'trace/render-a.csv').write_text(
                'experiment_phase,100,1,1,1\nwindow_enqueue,110,1000000,7,0\n'
                'experiment_phase,200,2,1,0\n'
                'window_gpu_last,300,4000000,5000000,7\n'
                'window_gpu_first,400,2000000,3000000,7\n'
                'displayed,500,20000000,7,0\n')
            result = clock.summarize(root)['phases'][0]['clock']['gpu_timeline']
            self.assertEqual(result['gpu_end_to_display_ms']['median'], 15)
            self.assertEqual(result['missing_timeline'], 0)

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
