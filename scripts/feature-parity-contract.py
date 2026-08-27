#!/usr/bin/env python3
"""Protect public KOEON user-facing feature contracts from export regressions."""

from __future__ import annotations

import argparse
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
    global ROOT
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=ROOT)
    args = parser.parse_args()
    ROOT = args.source.resolve()

    manifest = read("android/app/src/main/AndroidManifest.xml")
    gradle = read("android/app/build.gradle.kts")
    bitrate = read(
        "android/app/src/main/java/com/dennomuso/koeon/core/audio/AudioBitratePreset.kt"
    )
    android_ui = read("android/app/src/main/java/com/dennomuso/koeon/MainActivity.kt")
    android_session = read(
        "android/app/src/main/java/com/dennomuso/koeon/core/session/IntercomSessionManager.kt"
    )
    android_livekit = read(
        "android/app/src/main/java/com/dennomuso/koeon/core/livekit/LiveKitRoomController.kt"
    )
    android_diagnostics = read(
        "android/app/src/main/java/com/dennomuso/koeon/core/session/FieldDiagnostic.kt"
    )
    android_cues = read(
        "android/app/src/main/java/com/dennomuso/koeon/core/audio/TonePttCuePlayer.kt"
    )
    android_ptt = read(
        "android/app/src/main/java/com/dennomuso/koeon/core/ptt/PttController.kt"
    )
    android_rx = read(
        "android/app/src/main/java/com/dennomuso/koeon/core/ptt/RxAudioController.kt"
    )
    android_invite = read(
        "android/app/src/main/java/com/dennomuso/koeon/core/enrollment/InviteHandoff.kt"
    )
    ios_project = read("ios/KOEON.xcodeproj/project.pbxproj")
    ios_session = read("ios/KOEON/Core/Session/IntercomSessionController.swift")
    ios_rx = read("ios/KOEON/Core/PTT/RxAudioController.swift")
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
    require(
        all(marker in bitrate for marker in ("LOW(12)", "STANDARD(24)", "HIGH(48)")),
        "AUDIO_BITRATE_PRESETS",
    )
    require("val DEFAULT = STANDARD" in bitrate, "AUDIO_BITRATE_DEFAULT_24")
    require(
        "audio_bitrate_preset" in bitrate
        and "AudioBitratePreferenceStore" in android_session
        and "audioBitrateStore.save(preset)" in android_session,
        "AUDIO_BITRATE_PERSISTENCE",
    )
    require(
        "AudioTrackPublishDefaults(audioBitrate = preset.bitsPerSecond)" in android_livekit
        and "audioTrackPublishDefaults(audioBitratePreset)" in android_livekit
        and "audioBitratePreset," in android_session,
        "AUDIO_BITRATE_RUNTIME_MAPPING",
    )
    require(
        all(label in android_ui for label in ("12 kbps", "24 kbps", "48 kbps")),
        "AUDIO_BITRATE_UI",
    )
    require(
        all(key in android_diagnostics for key in (
            '"audioBitratePreset"',
            '"requestedAudioBitrateKbps"',
            '"effectiveAudioBitrateKbps"',
        )),
        "AUDIO_BITRATE_DIAGNOSTICS",
    )
    require(
        all(marker in android_cues for marker in ("TX_START", "TX_END", "RX_START", "RX_END")),
        "PTT_RX_CUE_CONTRACT",
    )
    require(
        "MAX_CONTINUOUS_TX_MS" in android_ptt
        and "acquire" in android_ptt
        and "renew" in android_ptt
        and "release" in android_ptt,
        "FLOOR_SAFETY_CONTRACT",
    )
    require(
        "RX_DRAINING" in android_rx
        and "RX_DRAIN_MIN_MS" in android_rx
        and "completeDrain" in android_rx,
        "RX_TAIL_CONTRACT",
    )
    require(
        "prewarmedTrack" in android_livekit and "prewarm()" in android_livekit,
        "P0_1_PTT_LATENCY_CONTRACT",
    )
    require(
        "Returns true only when a new, validated START has armed an RX generation" in android_rx
        and "remoteTalking =" in android_session
        and "localPttEligible(" in android_session
        and "rejectForRemoteBusy" in android_session,
        "P0_2_RX_STATE_DIVERGENCE_CONTRACT",
    )
    require(
        ".pointerInput(joined.sessionId)" in android_ui
        and "rememberUpdatedState(pttEnabled)" in android_ui
        and ".pointerInput(interactionEnabled)" not in android_ui
        and "tryAwaitRelease()" in android_ui
        and "appTouchPttCancel(\"pointer_cancel\")" in android_ui
        and all(
            marker in android_session
            for marker in (
                "appTouchDownCount",
                "appTouchUpCount",
                "appTouchCancelCount",
                "appTouchLastCancelReason",
            )
        ),
        "ANDROID_TOUCH_PTT_GESTURE_LIFETIME_CONTRACT",
    )
    require(
        'applicationId = "com.dennomuso.koeon"' in gradle
        and 'versionCode = 3' in gradle
        and 'versionName = "1.0.2"' in gradle,
        "ANDROID_1_0_2_IDENTITY_VERSION_CONTRACT",
    )
    require(
        "KOEON_API_BASE_URL" in gradle
        and 'signingConfig = signingConfigs.getByName("release")' in gradle,
        "ANDROID_RUNTIME_SIGNING_CONTRACT",
    )
    require(
        ios_project.count("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon") >= 2
        and (ROOT / "ios/KOEON/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png").is_file(),
        "IOS_APPICON_CONTRACT",
    )
    require(
        all(marker in ios_session for marker in ("telephone12k", "speech24k", "highQuality48k"))
        and "speech24k" in ios_session,
        "IOS_AUDIO_BITRATE_CONTRACT",
    )
    require(
        "rxDivergenceWatchdog" in ios_session
        and "rxDivergenceWatchdogMilliseconds = 250" in ios_rx,
        "IOS_RX_DIVERGENCE_CONTRACT",
    )
    print("FEATURE_PARITY_REQUIRED_SET=PASS")
    print("PERMANENT_PARITY_GATE=PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, UnicodeError) as error:
        print(f"FEATURE_PARITY_CONTRACT=FAIL:{error}", file=sys.stderr)
        raise SystemExit(1)
