import importlib.util
import pathlib
import threading
import unittest

spec = importlib.util.spec_from_file_location('physical_ptt', pathlib.Path(__file__).parents[1] / 'physical_ptt.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class HoldTest(unittest.TestCase):
    def test_rejects_unbounded_input_before_running(self):
        for value in [0, 11, float('nan'), float('inf'), True]:
            with self.assertRaises(ValueError):
                m.hold('adb', 'device', 10, 10, value, lambda: None)

    def test_observer_failure_still_releases_and_remote_has_trap(self):
        ended = threading.Event()
        commands = []
        def run(args, **kwargs):
            commands.append(args)
            if 'sh' in args:
                self.assertTrue(ended.wait(2))
            else:
                ended.set()
        def fail():
            raise RuntimeError('observer unavailable')
        with self.assertRaisesRegex(RuntimeError, 'observer unavailable'):
            m.hold('adb', 'device', 10, 20, 1, fail, run=run, sleep=lambda _: None)
        self.assertIn('trap', commands[0][-1])
        self.assertEqual(commands[-1][-3:], ['UP', '10', '20'])
        self.assertNotIn('swipe', ' '.join(commands[0]))

if __name__ == '__main__':
    unittest.main()
