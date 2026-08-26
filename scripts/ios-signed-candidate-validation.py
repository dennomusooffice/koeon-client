#!/usr/bin/env python3
"""Validate a signed iOS candidate without logging inspected values."""

from __future__ import annotations

import os
import plistlib
import sys
from pathlib import Path
from typing import Callable


Check = tuple[str, Callable[[], bool]]


def _load_plist(path: Path) -> dict:
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise ValueError("plist root must be a dictionary")
    return value


def _required_environment() -> dict[str, str]:
    names = (
        "APP_PATH",
        "SIGNED_ENTITLEMENTS",
        "PROFILE_PLIST",
        "APPLE_TEAM_ID",
        "KOEON_BUNDLE_ID",
        "MARKETING_VERSION",
        "BUILD_NUMBER",
        "KOEON_API_BASE_URL",
        "KOEON_ASSOCIATED_DOMAIN",
    )
    values = {name: os.environ.get(name, "") for name in names}
    if not all(values.values()):
        raise ValueError("required validation input is missing")
    return values


def _emit_result(checks: list[tuple[str, bool]]) -> int:
    print("SIGNED_CANDIDATE_VALIDATION_BEGIN")
    for name, passed in checks:
        print(f"{name}={'PASS' if passed else 'FAIL'}")
    passed = all(result for _, result in checks)
    print(f"SIGNED_CANDIDATE_VALIDATION_RESULT={'PASS' if passed else 'FAIL'}")
    print("SIGNED_CANDIDATE_VALIDATION_END")
    return 0 if passed else 1


def main() -> int:
    try:
        expected = _required_environment()
        app = Path(expected["APP_PATH"])
        info = _load_plist(app / "Info.plist")
        signed = _load_plist(Path(expected["SIGNED_ENTITLEMENTS"]))
        profile = _load_plist(Path(expected["PROFILE_PLIST"]))
    except Exception:
        return _emit_result([("SIGNED_CANDIDATE_INPUTS", False)])

    application_identifier = f'{expected["APPLE_TEAM_ID"]}.{expected["KOEON_BUNDLE_ID"]}'
    signed_domains = signed.get("com.apple.developer.associated-domains", [])
    profile_entitlements = profile.get("Entitlements", {})
    if not isinstance(profile_entitlements, dict):
        profile_entitlements = {}
    profile_domains = profile_entitlements.get("com.apple.developer.associated-domains", [])

    checks: list[Check] = [
        ("SIGNED_METADATA_BUNDLE_IDENTIFIER", lambda: info.get("CFBundleIdentifier") == expected["KOEON_BUNDLE_ID"]),
        ("SIGNED_METADATA_MARKETING_VERSION", lambda: info.get("CFBundleShortVersionString") == expected["MARKETING_VERSION"]),
        ("SIGNED_METADATA_BUILD_NUMBER", lambda: info.get("CFBundleVersion") == expected["BUILD_NUMBER"]),
        ("SIGNED_METADATA_RUNTIME_ENDPOINT", lambda: info.get("KOEONAPIBaseURL") == expected["KOEON_API_BASE_URL"]),
        ("SIGNED_METADATA_RUNTIME_ENDPOINT_NOT_PLACEHOLDER", lambda: info.get("KOEONAPIBaseURL") != "https://example.invalid"),
        ("SIGNED_ENTITLEMENT_APPLICATION_IDENTIFIER", lambda: signed.get("application-identifier") == application_identifier),
        ("SIGNED_ENTITLEMENT_TEAM_IDENTIFIER", lambda: signed.get("com.apple.developer.team-identifier") == expected["APPLE_TEAM_ID"]),
        ("SIGNED_ENTITLEMENT_APS_ENVIRONMENT", lambda: signed.get("aps-environment") == "production"),
        ("SIGNED_ENTITLEMENT_PUSH_TO_TALK", lambda: signed.get("com.apple.developer.push-to-talk") is True),
        ("SIGNED_ENTITLEMENT_ASSOCIATED_DOMAIN", lambda: expected["KOEON_ASSOCIATED_DOMAIN"] in signed_domains),
        ("SIGNED_ENTITLEMENT_GET_TASK_ALLOW_DISABLED", lambda: signed.get("get-task-allow") in (None, False)),
        ("PROFILE_ENTITLEMENT_APPLICATION_IDENTIFIER", lambda: profile_entitlements.get("application-identifier") == application_identifier),
        ("PROFILE_ENTITLEMENT_TEAM_IDENTIFIER", lambda: profile_entitlements.get("com.apple.developer.team-identifier") == expected["APPLE_TEAM_ID"]),
        ("PROFILE_ENTITLEMENT_APS_ENVIRONMENT", lambda: profile_entitlements.get("aps-environment") == "production"),
        ("PROFILE_ENTITLEMENT_PUSH_TO_TALK", lambda: profile_entitlements.get("com.apple.developer.push-to-talk") is True),
        ("PROFILE_ENTITLEMENT_ASSOCIATED_DOMAIN", lambda: expected["KOEON_ASSOCIATED_DOMAIN"] in profile_domains or "*" in profile_domains),
    ]

    results: list[tuple[str, bool]] = []
    for name, evaluate in checks:
        try:
            results.append((name, bool(evaluate())))
        except Exception:
            results.append((name, False))
    return _emit_result(results)


if __name__ == "__main__":
    sys.exit(main())
