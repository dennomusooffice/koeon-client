import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from lab import Lab, android_memory_mb, selected_aliases


class ReducedLabTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps({
            'androidSdk': '/unused/sdk', 'androidApp': 'example.app',
            'android': [{'alias': f'a{api-20}', 'api': api, 'port': 5554 + 2*(api-34),
                         'avd': f'api{api}'} for api in range(34, 38)],
            'ios': {'alias': 'ios', 'udid': 'simulator-id'}, 'iosApp': 'example.ios',
            'appium': 'http://127.0.0.1:4723',
        }))
        self.out = self.root / 'run'

    def test_invalid_selection_rejected(self):
        for selection in ['', 'a14,a14', 'phone', 'a14,']:
            with self.subTest(selection=selection), self.assertRaises(ValueError):
                selected_aliases(['a14', 'a15', 'ios'], selection)

    def test_android_only_never_calls_ios_or_appium(self):
        with patch('lab.command') as command:
            lab = Lab(self.config, self.out, 'a14,a15')
            with patch.object(lab, 'api', side_effect=AssertionError('Appium must not be contacted')):
                lab.ui_session()
                lab.shutdown()
            self.assertEqual(len(command.call_args_list), 2)
            self.assertEqual([call.args[0][2] for call in command.call_args_list],
                             ['emulator-5554', 'emulator-5556'])
            self.assertTrue(all(call.args[0][-2:] == ['emu', 'kill'] for call in command.call_args_list))

    def test_cleanup_cannot_silently_expand_saved_selection(self):
        self.out.mkdir()
        (self.out / 'selection.json').write_text(json.dumps({'selectedAliases': ['a14', 'a15']}))
        with patch('lab.command') as command, self.assertRaisesRegex(ValueError, 'Selection differs'):
            Lab(self.config, self.out)
        command.assert_not_called()

    def test_default_retains_full_sim5_and_simulator_validation(self):
        available = json.dumps({'devices': {'runtime': [{'udid': 'simulator-id'}]}})
        with patch('lab.command', return_value=available):
            lab = Lab(self.config, self.out)
        self.assertEqual(lab.keys, ['a14', 'a15', 'a16', 'a17', 'ios'])
        self.assertTrue(lab.ios_enabled)
        with patch('lab.command', return_value='{"devices": {}}'), self.assertRaises(ValueError):
            Lab(self.config, self.root / 'other', 'ios')

    def test_single_endpoint_cannot_pass_control_vacuously(self):
        lab = Lab(self.config, self.out, 'a15')
        with self.assertRaisesRegex(ValueError, 'at least two'):
            lab.controls(1)

    def test_api37_ram_budget_matches_emulator_minimum(self):
        self.assertEqual(android_memory_mb({'api': 35}), 1536)
        self.assertEqual(android_memory_mb({'api': 37, 'memoryMb': 1536}), 4096)
        self.assertEqual(android_memory_mb({'api': 37, 'memoryMb': 6144}), 6144)
        with self.assertRaises(ValueError):
            android_memory_mb({'api': 37, 'memoryMb': 0})


if __name__ == '__main__':
    unittest.main()
