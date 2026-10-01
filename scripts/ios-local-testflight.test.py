#!/usr/bin/env python3
"""Exercise local release gates and cleanup without Apple credentials or upload."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("local_release", Path(__file__).with_name("ios-local-testflight.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class LocalReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.key = self.root / "test.p8"
        self.key.write_text("test-only-key-material")
        self.key.chmod(0o600)
        self.config = dict(APPLE_TEAM_ID="ABCDEFGHIJ", KOEON_BUNDLE_ID="net.sample.client",
                           KOEON_API_BASE_URL="https://api.sample.test", KOEON_ASSOCIATED_DOMAIN="applinks:sample.test",
                           ASC_KEY_ID="1234567890", ASC_ISSUER_ID="01234567-89ab-cdef-0123-456789abcdef",
                           ASC_KEY_PATH=str(self.key))
        self.config_path = self.root / "config.json"

    def read(self):
        self.config_path.write_text(json.dumps(self.config))
        self.config_path.chmod(0o600)
        return release.read_config(self.config_path)

    def args(self, action, confirm=None):
        return argparse.Namespace(action=action, version="1.0.8", build="10", confirm=confirm)

    def test_valid_configuration(self):
        self.assertEqual(self.read(), {**self.config, "ASC_KEY_PATH": str(self.key.resolve())})

    def test_rejects_unsafe_endpoints_without_echoing_them(self):
        for endpoint in ("http://api.sample.test", "https://example.invalid", "https://other.invalid",
                         "https://user:secret@api.sample.test", "https://api.sample.test?secret=value",
                         "https://api.sample.test/#secret", "https://api.sample.test/\nsecret"):
            with self.subTest(endpoint=endpoint):
                self.config["KOEON_API_BASE_URL"] = endpoint
                with self.assertRaises(ValueError) as error:
                    self.read()
                self.assertNotIn(endpoint, str(error.exception))

    def test_rejects_shared_key_permissions(self):
        self.key.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "permissions"):
            self.read()

    def test_upload_requires_explicit_confirmation(self):
        with self.assertRaisesRegex(ValueError, "confirm"):
            release.validate_request(self.args("upload"))
        release.validate_request(self.args("upload", "UPLOAD_TESTFLIGHT"))
        release.validate_request(self.args("candidate"))

    def test_rejects_invalid_version_and_build(self):
        for field, value in (("version", "1"), ("version", "1.2; command"), ("build", "0"), ("build", "-1")):
            args = self.args("candidate")
            setattr(args, field, value)
            with self.assertRaises(ValueError):
                release.validate_request(args)

    def test_candidate_isolated_and_cleans_credentials_on_failure(self):
        captured = {}

        def step(label, command, env, log):
            if label == "Signed candidate":
                captured.update(env)
                self.assertEqual(env["RELEASE_MODE"], "CANDIDATE_ONLY")
                self.assertNotEqual(Path(env["CLIENT_SOURCE_DIR"]), release.ROOT)
                credential = Path(env["IOS_CREDENTIAL_DIR"]) / "AuthKey.p8"
                self.assertTrue(credential.is_file())
                self.assertEqual(credential.stat().st_mode & 0o777, 0o600)
                raise ValueError("simulated signing failure")

        with patch.object(release, "DEFAULT_CONFIG", self.config_path), \
             patch.object(release.sys, "platform", "darwin"), \
             patch.object(release.shutil, "which", return_value="/test/node"), \
             patch.object(release.subprocess, "check_output", return_value="22"), \
             patch.object(release, "git_value", side_effect=["", "a" * 40, "b" * 40]), \
             patch.object(release, "run_step", side_effect=step), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(ValueError, "simulated"):
                release.execute(self.args("candidate"), self.read())
        self.assertFalse(Path(captured["RUNNER_TEMP"]).exists())
        self.assertTrue(self.key.exists())
        self.assertTrue(self.config_path.exists())

    def test_dirty_source_blocks_before_signing(self):
        with patch.object(release.sys, "platform", "darwin"), \
             patch.object(release.shutil, "which", return_value="/test/node"), \
             patch.object(release.subprocess, "check_output", return_value="22"), \
             patch.object(release, "git_value", return_value=" M changed.swift"), \
             patch.object(release, "run_step") as step:
            with self.assertRaisesRegex(ValueError, "Commit"):
                release.execute(self.args("candidate"), self.read())
            step.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
