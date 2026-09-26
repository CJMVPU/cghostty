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
                'trace_drop,10,17,0,0\n')
            result = trace.summarize(root)['local']
            self.assertEqual(result['main_queue_wait_ms']['mean'], 8)
            self.assertEqual(result['gpu_execution_ms']['mean'], 2)
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


if __name__ == '__main__':
    unittest.main()
