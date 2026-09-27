import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'summarize-render-trace.py'
spec = importlib.util.spec_from_file_location('render_trace', SCRIPT)
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


class RenderTraceTests(unittest.TestCase):
    def test_reference_excludes_warmup_and_missing_presentation_time(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'samples.json').write_text(json.dumps({
                'latency': 1, 'requestedMaximum': True, 'screenMaximumFPS': 120,
                'samples': [
                    {'sequence': 0, 'displayed': 100},
                    {'sequence': 20, 'displayed': 0},
                    {'sequence': 21, 'callback': 1, 'submit': 1.001,
                     'deadline': 1.008, 'prediction': 1.04, 'displayed': 1.04},
                ],
            }))
            result = trace.summarize(root)['reference']
            self.assertEqual(result['valid_samples'], 1)
            self.assertEqual(result['metal_submit_to_display_ms']['median'], 39)
            self.assertEqual(result['metal_deadline_to_prediction_ms']['median'], 32)

    def test_metal_timestamps_pair_per_surface_and_ignore_unpresented_drawables(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'render-1.csv').write_text(
                'metal_tick,1,11000000,12000000,1\n'
                'metal_callback,1,9000000,1,0\n'
                'metal_state,1,0,1000,0\n'
                'present_submit,2,10000000,1,0\n'
                'displayed,3,14000000,1,0\n'
                'displayed,4,0,2,0\n')
            (root / 'render-2.csv').write_text(
                'metal_tick,5,1000000,30000000,1\n'
                'present_submit,6,25000000,1,0\n'
                'displayed,7,28000000,1,0\n')
            result = trace.summarize(root)['local']
            self.assertEqual(result['metal_displayed_frames'], 2)
            self.assertEqual(result['metal_submit_to_display_ms']['median'], 3.5)
            self.assertEqual(result['metal_submit_to_display_ms']['p99'], 4)
            self.assertEqual(result['metal_prediction_error_ms']['mean'], 0)
            self.assertEqual(result['metal_callback_to_submit_ms']['median'], 1)
            self.assertEqual(result['metal_callback_to_deadline_ms']['median'], 2)
            self.assertEqual(result['metal_submitted_after_deadline'], 1)
            self.assertEqual(result['metal_resumes'], 1)
            self.assertEqual(result['metal_preferred_frame_latencies'], [1])
            self.assertIsNone(result['main_queue_wait_ms'])

    def test_overlay_counts_distinguish_reference_work_from_submitted_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'render-1.csv').write_text(
                'overlay,1,3202,80,121\n'
                'overlay,2,3202,0,0\n')
            result = trace.summarize(root)['local']
            self.assertEqual(result['overlay_reference_instances'], 6404)
            self.assertEqual(result['overlay_submitted_instances'], 80)
            self.assertEqual(result['overlay_scissor_pixels']['max'], 121)

    def test_raw_traces_separate_queue_wait_from_gpu_and_sync_draws(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'render-1.csv').write_text(
                'gpu,1,2000000,1,0\n'
                'present,2,8000000,1,0\n'
                'present,3,0,2,1\n'
                'present_drop,4,1,3,0\n'
                'present_drop,5,4,4,0\n'
                'draw_lock,6,5000000,1,0\n'
                'draw_total,7,7000000,1,0\n'
                'vsync,8,16666667,0,0\n'
                'rebuild,9,3000000,0,0\n'
                'snapshot,9,11000000,0,0\n'
                'snapshot_gpu,9,500000,1,0\n'
                'trace_drop,10,17,0,0\n')
            result = trace.summarize(root)['local']
            self.assertEqual(result['main_queue_wait_ms']['mean'], 8)
            self.assertEqual(result['gpu_execution_ms']['mean'], 2)
            self.assertEqual(result['gpu_execution_ms']['count'], 1)
            self.assertEqual(result['snapshot_wall_ms']['mean'], 11)
            self.assertEqual(result['snapshot_gpu_ms']['mean'], 0.5)
            self.assertEqual(result['draw_lock_wait_ms']['max'], 5)
            self.assertEqual(result['layer_assignments'], 2)
            self.assertEqual(result['trace_records_dropped'], 17)
            self.assertEqual(result['synchronous_layer_assignments'], 1)
            self.assertEqual(result['presentation_drops']['replaced'], 1)
            self.assertEqual(result['presentation_drops']['target_reused'], 1)
            self.assertEqual(result['swap_chain_rebuild_ms']['mean'], 3)

    def test_legacy_attachments_sort_timestamps_without_crossing_surfaces(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'manifest.json').write_text(json.dumps([{'attachments': [
                {'suggestedHumanReadableName': 'perf-vsync-motion-first', 'exportedFileName': 'a.csv'},
                {'suggestedHumanReadableName': 'perf-vsync-motion-second', 'exportedFileName': 'b.csv'},
                {'suggestedHumanReadableName': 'screenshot', 'exportedFileName': 'ignored.png'},
            ]}]))
            (root / 'a.csv').write_text('draw,9000000,1000000,20,2\ndraw,1000000,1000000,0,2\n')
            (root / 'b.csv').write_text('draw,50000000,2000000,10,0\n')
            result = trace.summarize(root)['vsync-motion']
            self.assertEqual(result['surfaces'], 2)
            self.assertEqual(result['draw_interval_ms']['count'], 1)
            self.assertEqual(result['draw_interval_ms']['mean'], 8)
            self.assertEqual(result['copied_cell_bytes'], 30)
            self.assertIsNone(result['main_queue_wait_ms'])
            self.assertIsNone(result['vsync_interval_ms'])
            self.assertIsNone(result['overlay_reference_instances'])


if __name__ == '__main__':
    unittest.main()
