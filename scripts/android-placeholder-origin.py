#!/usr/bin/env python3
"""Classify Android release placeholder strings without printing endpoint values."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


PLACEHOLDER = "https://example.invalid"
APP_PREFIX = "com.dennomuso.koeon."
RUNTIME_CLASSES = {
    "com.dennomuso.koeon.BuildConfig",
    "com.dennomuso.koeon.core.api.HttpKoeonApi",
    "com.dennomuso.koeon.core.session.IntercomSessionManager",
}


def normalized_class(descriptor: str) -> str:
    return descriptor.removeprefix("L").removesuffix(";").replace("/", ".")


def string_owners(dump: str, value: str) -> list[str]:
    current_class: str | None = None
    owners: list[str] = []
    for line in dump.splitlines():
        descriptor = re.search(r"Class descriptor\s+: '(L[^']+;)'", line)
        if descriptor:
            current_class = normalized_class(descriptor.group(1))
        if value in line and ("const-string" in line or re.search(r"\bvalue\s+:", line)):
            owners.append(current_class or "UNKNOWN")
    return owners


def classify(owners: set[str]) -> str:
    if not owners or "UNKNOWN" in owners:
        return "UNKNOWN"
    if owners & RUNTIME_CLASSES:
        return "PRODUCT_RUNTIME_PATH"
    if all(owner.startswith(APP_PREFIX) for owner in owners):
        return "APP_UNRELATED"
    if all(not owner.startswith(APP_PREFIX) for owner in owners):
        return "THIRD_PARTY_UNRELATED"
    return "UNKNOWN"


def package_name(class_name: str) -> str:
    return class_name.rsplit(".", 1)[0] if "." in class_name else class_name


def run_self_test() -> None:
    sample = f"""
Class descriptor  : 'Lcom/dennomuso/koeon/core/enrollment/InviteHandoffKt;'
      value         : \"{PLACEHOLDER}\"
Class descriptor  : 'Lcom/dennomuso/koeon/core/enrollment/InviteInputParser;'
001b78: const-string v3, \"{PLACEHOLDER}\" // string@00e2
Class descriptor  : 'Lcom/dennomuso/koeon/BuildConfig;'
      value         : \"https://protected.example.test\"
Class descriptor  : 'Lcom/dennomuso/koeon/core/session/IntercomSessionManager;'
001b78: const-string v3, \"https://protected.example.test\" // string@00e2
"""
    owners = string_owners(sample, PLACEHOLDER)
    assert owners == [
        "com.dennomuso.koeon.core.enrollment.InviteHandoffKt",
        "com.dennomuso.koeon.core.enrollment.InviteInputParser",
    ]
    assert classify(set(owners)) == "APP_UNRELATED"
    assert string_owners(sample, "https://protected.example.test") == [
        "com.dennomuso.koeon.BuildConfig",
        "com.dennomuso.koeon.core.session.IntercomSessionManager",
    ]
    assert classify({"UNKNOWN"}) == "UNKNOWN"
    print("ANDROID_PLACEHOLDER_ORIGIN_SELF_TEST=PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dex-dir")
    parser.add_argument("--dexdump")
    parser.add_argument("--source-root")
    parser.add_argument("--mode", choices=("diagnostic", "enforce"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return 0
    if not all((args.dex_dir, args.dexdump, args.source_root, args.mode)):
        parser.error("release analysis arguments are required")

    expected = os.environ.get("EXPECTED_ENDPOINT", "")
    if not expected or expected == PLACEHOLDER:
        raise SystemExit("ANDROID_RUNTIME_CONFIG_CONTRACT=FAIL")

    placeholder_dex_count = 0
    placeholder_binary_count = 0
    placeholder_owners: list[str] = []
    expected_owners: list[str] = []
    for dex in sorted(Path(args.dex_dir).glob("classes*.dex")):
        payload = dex.read_bytes()
        binary_count = payload.count(PLACEHOLDER.encode("utf-8"))
        expected_present = expected.encode("utf-8") in payload
        if not binary_count and not expected_present:
            continue
        completed = subprocess.run(
            [args.dexdump, "-d", str(dex)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if binary_count:
            placeholder_dex_count += 1
            placeholder_binary_count += binary_count
            placeholder_owners.extend(string_owners(completed.stdout, PLACEHOLDER))
        if expected_present:
            expected_owners.extend(string_owners(completed.stdout, expected))

    owners = set(placeholder_owners)
    if placeholder_binary_count and (not owners or "UNKNOWN" in owners):
        classification = "UNKNOWN"
    elif owners:
        classification = classify(owners)
    else:
        classification = "NOT_PRESENT"

    expected_set = set(expected_owners)
    build_config_ok = "com.dennomuso.koeon.BuildConfig" in expected_set
    runtime_consumer_dex_ok = "com.dennomuso.koeon.core.session.IntercomSessionManager" in expected_set
    source = Path(args.source_root, "android/app/src/main/java/com/dennomuso/koeon/core/session/IntercomSessionManager.kt").read_text(encoding="utf-8")
    runtime_consumer_source_ok = "BuildConfig.KOEON_BACKEND_URL" in source and "HttpKoeonApi(" in source
    debug_build_config_packaged = "com.dennomuso.koeon.BuildConfig" in owners
    app_placeholder = any(owner.startswith(APP_PREFIX) for owner in owners)

    print(f"PLACEHOLDER_DEX_COUNT={placeholder_dex_count}")
    print(f"PLACEHOLDER_OCCURRENCE_COUNT={len(placeholder_owners)}")
    if owners:
        packages = sorted({package_name(owner) for owner in owners})
        print(f"PLACEHOLDER_ORIGIN_PACKAGE={','.join(packages)}")
        print(f"PLACEHOLDER_ORIGIN_CLASS={','.join(sorted(owners))}")
    else:
        print("PLACEHOLDER_ORIGIN_PACKAGE=N/A")
        print("PLACEHOLDER_ORIGIN_CLASS=N/A")

    if build_config_ok:
        print("RELEASE_BUILD_CONFIG_ENDPOINT_PRESENT=PASS")
        print("RELEASE_BUILD_CONFIG_ENDPOINT_PLACEHOLDER=NO")
    else:
        print("RELEASE_BUILD_CONFIG_ENDPOINT_PRESENT=FAIL")
    print(f"DEBUG_BUILD_CONFIG_PACKAGED_IN_RELEASE={'YES' if debug_build_config_packaged else 'NO'}")
    print(f"RUNTIME_CONSUMER_USES_BUILD_CONFIG={'PASS' if runtime_consumer_source_ok and runtime_consumer_dex_ok else 'FAIL'}")
    print(f"APP_PACKAGE_RUNTIME_PLACEHOLDER={'YES' if app_placeholder else 'NO'}")
    print("APK_EXPECTED_RUNTIME_ENDPOINT_PRESENT=" + ("PASS" if expected_set else "FAIL"))

    if classification == "UNKNOWN":
        print("PLACEHOLDER_ORIGIN_CLASSIFIED=FAIL")
        print("PLACEHOLDER_ORIGIN_CLASSIFICATION=UNKNOWN")
        return 1
    if classification != "NOT_PRESENT":
        print("PLACEHOLDER_ORIGIN_CLASSIFIED=PASS")
        print(f"PLACEHOLDER_ORIGIN_CLASSIFICATION={classification}")
    if not (build_config_ok and runtime_consumer_source_ok and runtime_consumer_dex_ok and expected_set):
        return 1
    if args.mode == "enforce" and owners:
        print("APK_RUNTIME_ENDPOINT_PLACEHOLDER=YES")
        return 1
    print("APK_RUNTIME_ENDPOINT_CONFIGURED=PASS")
    print("APK_RUNTIME_ENDPOINT_PLACEHOLDER=NO" if not owners else "APK_RUNTIME_ENDPOINT_PLACEHOLDER=DIAGNOSTIC_ONLY")
    print("ANDROID_RELEASE_VALIDATOR_SEMANTICS=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
