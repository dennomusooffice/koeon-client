#!/usr/bin/env python3
"""Validate the official iOS AppIcon without disclosing release configuration."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import struct
from pathlib import Path


EXPECTED_BLOB = "586f3968c3eed7ce9ddde7db3173c76f9641da4b"
EXPECTED_ROOT_CONTENTS = {"info": {"author": "xcode", "version": 1}}
EXPECTED_APPICON_CONTENTS = {
    "images": [
        {
            "filename": "AppIcon-1024.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
    ],
    "info": {"author": "xcode", "version": 1},
}


def fail(check: str) -> None:
    print(f"{check}=FAIL")
    raise SystemExit(1)


def validate_source(root: Path) -> None:
    catalog = root / "ios" / "KOEON" / "Assets.xcassets"
    icon_set = catalog / "AppIcon.appiconset"
    icon = icon_set / "AppIcon-1024.png"
    try:
        root_contents = json.loads((catalog / "Contents.json").read_text(encoding="utf-8"))
        icon_contents = json.loads((icon_set / "Contents.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("APPICON_CONTENTS_VALID")
    if root_contents != EXPECTED_ROOT_CONTENTS or icon_contents != EXPECTED_APPICON_CONTENTS:
        fail("APPICON_CONTENTS_VALID")
    print("APPICON_CONTENTS_VALID=PASS")

    try:
        data = icon.read_bytes()
    except OSError:
        fail("APPICON_1024_PRESENT")
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        fail("APPICON_1024_PRESENT")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (1024, 1024):
        fail("APPICON_1024_PRESENT")
    print("APPICON_1024_PRESENT=PASS")

    blob = hashlib.sha1(f"blob {len(data)}\0".encode("ascii") + data).hexdigest()
    if blob != EXPECTED_BLOB:
        fail("APPICON_SOURCE_PROVENANCE_VERIFIED")
    print("APPICON_SOURCE_PROVENANCE_VERIFIED=PASS")


def validate_app(app: Path) -> None:
    assets = app / "Assets.car"
    info_path = app / "Info.plist"
    if not assets.is_file() or assets.stat().st_size == 0:
        fail("APPICON_COMPILED_INTO_APP")
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException):
        fail("APPICON_COMPILED_INTO_APP")
    primary = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
    icon_name = primary.get("CFBundleIconName")
    icon_files = primary.get("CFBundleIconFiles", [])
    if icon_name != "AppIcon" and not any(str(value).startswith("AppIcon") for value in icon_files):
        fail("APPICON_COMPILED_INTO_APP")
    print("APPICON_COMPILED_INTO_APP=PASS")


def main() -> None:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--source", type=Path)
    group.add_argument("--app", type=Path)
    args = parser.parse_args()
    if args.source is not None:
        validate_source(args.source.resolve())
    else:
        validate_app(args.app.resolve())


if __name__ == "__main__":
    main()
