#!/usr/bin/env python3
"""Offline calibration: do not turn a clock-drift false negative into a product bug."""
import importlib.util
from pathlib import Path
import unittest
import numpy as np

spec = importlib.util.spec_from_file_location('probe', Path(__file__).with_name('emulator-audio-probe.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class SignalDetectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        t = np.arange(6 * 48000) / 48000
        frequency = 170 + 120*np.sin(2*np.pi*.73*t) + 15*t
        phase = np.cumsum(2*np.pi*frequency/48000)
        cls.source = (4000 * (.6+.4*np.sin(2*np.pi*2.1*t)) *
                      (np.sin(phase)+.4*np.sin(2*phase)+.2*np.sin(3*phase))).astype(np.int16)

    def test_scaled_delayed_signal_preserves_order(self):
        audio = np.concatenate([np.zeros(48000), self.source * .4, np.zeros(48000)])
        result = probe.correlation(audio, self.source)
        self.assertGreater(result['correlation'], .99)
        self.assertTrue(result['orderedSpeechSegments'])

    def test_small_clock_drift_still_matches_short_segments(self):
        warped = np.interp(np.arange(0, len(self.source)-1, 1.001), np.arange(len(self.source)), self.source)
        result = probe.correlation(np.concatenate([np.zeros(48000), warped, np.zeros(48000)]), self.source)
        self.assertTrue(result['orderedSpeechSegments'])

    def test_reversed_signal_does_not_satisfy_temporal_order(self):
        result = probe.correlation(np.concatenate([np.zeros(48000), self.source[::-1], np.zeros(48000)]), self.source)
        self.assertFalse(result['orderedSpeechSegments'])

    def test_independent_noise_and_silence_are_rejected(self):
        noise = np.random.default_rng(5).normal(0, 3000, len(self.source)+96000)
        for audio in [noise, np.zeros(len(noise))]:
            result = probe.correlation(audio, self.source)
            self.assertLess(result['correlation'], .1)
            self.assertFalse(result['orderedSpeechSegments'])


if __name__ == '__main__':
    unittest.main()
