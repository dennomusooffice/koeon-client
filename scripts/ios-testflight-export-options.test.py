import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class AudienceExportTests(unittest.TestCase):
    def test_exported_plist_audience_and_signing(self):
        script = Path(__file__).with_name("ios-testflight-export-options.py")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "export.plist"
            for audience, internal in (("internal", True), ("external", False)):
                subprocess.run([sys.executable, str(script), audience, "TEAM123456", str(path)], check=True)
                options = plistlib.loads(path.read_bytes())
                self.assertIs(options["testFlightInternalTestingOnly"], internal)
                self.assertEqual(options["method"], "app-store-connect")
                self.assertEqual(options["destination"], "export")
                self.assertEqual(options["signingCertificate"], "Apple Distribution")
                self.assertFalse(options["manageAppVersionAndBuildNumber"])
            path.unlink()
            result = subprocess.run([sys.executable, str(script), "typo", "TEAM123456", str(path)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
