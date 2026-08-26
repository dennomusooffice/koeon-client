#!/usr/bin/env python3
"""Protect public KOEON user-facing feature contracts from export regressions."""

from __future__ import annotations

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
INVITE_HOST = "koeon.muso-apps.net"


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(condition: bool, name: str) -> None:
    if not condition:
        raise AssertionError(name)
    print(f"{name}=PASS")


def main() -> int:
    manifest = read("android/app/src/main/AndroidManifest.xml")
    android_invite = read(
        "android/app/src/main/java/com/dennomuso/koeon/core/enrollment/InviteHandoff.kt"
    )
    ios_invite = read("ios/KOEON/Core/InviteHandoff.swift")
    ios_entitlements = read("ios/KOEON/KOEON.entitlements")

    icon_paths = [
        "android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png",
        "android/app/src/main/res/drawable-xxxhdpi/ic_launcher_monochrome.png",
        "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml",
        "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml",
        "android/app/src/main/res/values/icon_colors.xml",
    ]
    for density in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"):
        icon_paths.extend(
            [
                f"android/app/src/main/res/mipmap-{density}/ic_launcher.png",
                f"android/app/src/main/res/mipmap-{density}/ic_launcher_round.png",
            ]
        )

    require(all((ROOT / path).is_file() for path in icon_paths), "ANDROID_APPICON_RESOURCE_PRESENT")
    require(
        'android:icon="@mipmap/ic_launcher"' in manifest
        and 'android:roundIcon="@mipmap/ic_launcher_round"' in manifest,
        "ANDROID_MANIFEST_ICON_REFERENCE",
    )
    require(
        f'android:host="{INVITE_HOST}"' in manifest
        and 'android:path="/join"' in manifest
        and "example.invalid" not in manifest,
        "ANDROID_INVITE_DEEP_LINK_CONTRACT",
    )
    require(
        f'https://{INVITE_HOST}' in android_invite and "example.invalid" not in android_invite,
        "ANDROID_INVITE_PARSER_CONTRACT",
    )
    require(
        f'private static let trustedHost = "{INVITE_HOST}"' in ios_invite
        and "example.invalid" not in ios_invite,
        "IOS_INVITE_PARSER_CONTRACT",
    )
    require(
        f"applinks:{INVITE_HOST}" in ios_entitlements and "example.invalid" not in ios_entitlements,
        "IOS_ASSOCIATED_DOMAIN_CONTRACT",
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, UnicodeError) as error:
        print(f"FEATURE_PARITY_CONTRACT=FAIL:{error}", file=sys.stderr)
        raise SystemExit(1)
