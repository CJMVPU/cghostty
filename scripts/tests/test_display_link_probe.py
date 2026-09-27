import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('probe', Path(__file__).resolve().parents[1] / 'summarize-display-link-probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class DisplayLinkProbeTests(unittest.TestCase):
    def test_warmup_and_unpresented_frames_do_not_become_latency_samples(self):
        base = dict(callback=1, submit=1.001, deadline=1.008, prediction=0,
                    acquire=.0001, active=True, key=True)
        data = dict(arguments=['view'], device='test', screen='test', os='test',
                    screenMaximumFPS=120, error='', warmupFrames=20,
                    samples=[dict(base, sequence=0, displayed=2),
                             dict(base, sequence=20, displayed=0),
                             dict(base, sequence=21, displayed=1.025)])
        result = probe.summarize(data)
        self.assertEqual(result['samples'], 2)
        self.assertEqual(result['not_displayed'], 1)
        self.assertEqual(result['submit_to_display_ms']['count'], 1)
        self.assertEqual(result['submit_to_display_ms']['median'], 24)
        self.assertIsNone(result['deadline_to_prediction_ms'])
        self.assertTrue(result['all_foreground'])
        data['samples'][1]['key'] = False
        self.assertFalse(probe.summarize(data)['all_foreground'])
