#!/usr/bin/env python3
"""Tests for secret-safe signed candidate validation diagnostics."""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("ios-signed-candidate-validation.py")
CHECK_NAMES = (
    "SIGNED_METADATA_BUNDLE_IDENTIFIER",
    "SIGNED_METADATA_MARKETING_VERSION",
    "SIGNED_METADATA_BUILD_NUMBER",
    "SIGNED_METADATA_RUNTIME_ENDPOINT",
    "SIGNED_METADATA_RUNTIME_ENDPOINT_NOT_PLACEHOLDER",
    "SIGNED_ENTITLEMENT_APPLICATION_IDENTIFIER",
    "SIGNED_ENTITLEMENT_TEAM_IDENTIFIER",
    "SIGNED_ENTITLEMENT_APS_ENVIRONMENT",
    "SIGNED_ENTITLEMENT_PUSH_TO_TALK",
    "SIGNED_ENTITLEMENT_ASSOCIATED_DOMAIN",
    "SIGNED_ENTITLEMENT_GET_TASK_ALLOW_DISABLED",
    "PROFILE_ENTITLEMENT_APPLICATION_IDENTIFIER",
    "PROFILE_ENTITLEMENT_TEAM_IDENTIFIER",
    "PROFILE_ENTITLEMENT_APS_ENVIRONMENT",
    "PROFILE_ENTITLEMENT_PUSH_TO_TALK",
    "PROFILE_ENTITLEMENT_ASSOCIATED_DOMAIN",
)


class SignedCandidateValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.app = self.root / "Candidate.app"
        self.app.mkdir()
        self.signed_path = self.root / "signed.plist"
        self.profile_path = self.root / "profile.plist"
        self.values = {
            "team": "PRIVATE_TEAM_SENTINEL",
            "bundle": "private.bundle.sentinel",
            "version": "9.8.7",
            "build": "987654321",
            "endpoint": "https://private-runtime.invalid/path?token=TOKEN_SENTINEL",
            "domain": "applinks:private-domain.invalid",
        }
        application_identifier = f'{self.values["team"]}.{self.values["bundle"]}'
        self.info = {
            "CFBundleIdentifier": self.values["bundle"],
            "CFBundleShortVersionString": self.values["version"],
            "CFBundleVersion": self.values["build"],
            "KOEONAPIBaseURL": self.values["endpoint"],
        }
        self.signed = {
            "application-identifier": application_identifier,
            "com.apple.developer.team-identifier": self.values["team"],
            "aps-environment": "production",
            "com.apple.developer.push-to-talk": True,
            "com.apple.developer.associated-domains": [self.values["domain"]],
            "get-task-allow": False,
        }
        self.profile = {"Entitlements": dict(self.signed)}

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _write(path: Path, value: dict) -> None:
        with path.open("wb") as stream:
            plistlib.dump(value, stream)

    def run_validation(self) -> subprocess.CompletedProcess[str]:
        self._write(self.app / "Info.plist", self.info)
        self._write(self.signed_path, self.signed)
        self._write(self.profile_path, self.profile)
        environment = os.environ.copy()
        environment.update({
            "APP_PATH": str(self.app),
            "SIGNED_ENTITLEMENTS": str(self.signed_path),
            "PROFILE_PLIST": str(self.profile_path),
            "APPLE_TEAM_ID": self.values["team"],
            "KOEON_BUNDLE_ID": self.values["bundle"],
            "MARKETING_VERSION": self.values["version"],
            "BUILD_NUMBER": self.values["build"],
            "KOEON_API_BASE_URL": self.values["endpoint"],
            "KOEON_ASSOCIATED_DOMAIN": self.values["domain"],
        })
        return subprocess.run(
            [sys.executable, str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def assert_secret_safe(self, result: subprocess.CompletedProcess[str]) -> None:
        output = result.stdout + result.stderr
        for value in self.values.values():
            self.assertNotIn(value, output)
        self.assertNotIn("TOKEN_SENTINEL", output)
        self.assertNotIn("Entitlements", output)

    def check_results(self, result: subprocess.CompletedProcess[str]) -> dict[str, str]:
        parsed: dict[str, str] = {}
        for line in result.stdout.splitlines():
            name, separator, value = line.partition("=")
            if separator and name in CHECK_NAMES:
                parsed[name] = value
        return parsed

    def test_all_checks_pass(self) -> None:
        result = self.run_validation()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.check_results(result), {name: "PASS" for name in CHECK_NAMES})
        self.assertIn("SIGNED_CANDIDATE_VALIDATION_RESULT=PASS", result.stdout)
        self.assert_secret_safe(result)

    def test_single_failure_reports_only_that_check(self) -> None:
        self.info["CFBundleVersion"] = "ACTUAL_BUILD_SENTINEL"
        result = self.run_validation()
        self.assertNotEqual(result.returncode, 0)
        expected = {name: "PASS" for name in CHECK_NAMES}
        expected["SIGNED_METADATA_BUILD_NUMBER"] = "FAIL"
        self.assertEqual(self.check_results(result), expected)
        self.assertIn("SIGNED_CANDIDATE_VALIDATION_RESULT=FAIL", result.stdout)
        self.assertNotIn("ACTUAL_BUILD_SENTINEL", result.stdout + result.stderr)
        self.assert_secret_safe(result)

    def test_multiple_failures_are_reported_independently(self) -> None:
        self.info["CFBundleShortVersionString"] = "ACTUAL_VERSION_SENTINEL"
        self.signed["com.apple.developer.push-to-talk"] = False
        self.profile["Entitlements"]["com.apple.developer.associated-domains"] = []
        result = self.run_validation()
        self.assertNotEqual(result.returncode, 0)
        expected = {name: "PASS" for name in CHECK_NAMES}
        expected["SIGNED_METADATA_MARKETING_VERSION"] = "FAIL"
        expected["SIGNED_ENTITLEMENT_PUSH_TO_TALK"] = "FAIL"
        expected["PROFILE_ENTITLEMENT_ASSOCIATED_DOMAIN"] = "FAIL"
        self.assertEqual(self.check_results(result), expected)
        self.assertNotIn("ACTUAL_VERSION_SENTINEL", result.stdout + result.stderr)
        self.assert_secret_safe(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
