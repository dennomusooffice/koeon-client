#!/usr/bin/env python3
"""Observe real app recovery after temporary network loss on an Android AVD.

Run with --serial emulator-NNNN --output-dir PRIVATE_DIRECTORY. This changes
only the selected AVD and restores its original enabled network settings.
It does not transmit audio or prove that a READY receiver is audible.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.serial):
        parser.error('Only an explicitly selected emulator serial is allowed')
    os.umask(0o077)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    def adb(*values):
        return subprocess.check_output([args.adb, '-s', args.serial, *values], text=True, timeout=30).strip()

    if adb('shell', 'getprop', 'ro.kernel.qemu') != '1':
        raise RuntimeError('Refusing to change networking on a physical device')
    if adb('shell', 'cmd', 'connectivity', 'airplane-mode') != 'disabled':
        raise RuntimeError('Start with airplane mode disabled; original state left unchanged')
    if adb('shell', 'settings', 'get', 'global', 'wifi_on') != '1':
        raise RuntimeError('Start with Wi-Fi enabled; original state left unchanged')
    rows = []
    start = time.monotonic()

    def capture(stage):
        adb('shell', 'uiautomator', 'dump', '/sdcard/koeon-recovery.xml')
        xml = adb('exec-out', 'cat', '/sdcard/koeon-recovery.xml')
        (args.output_dir / (stage + '.xml')).write_text(xml)
        nodes = list(ET.fromstring(xml).iter('node'))
        row = {'stage': stage, 'elapsedSeconds': round(time.monotonic() - start, 2),
               'ready': any(n.get('content-desc') == 'Push to talk, READY' for n in nodes),
               'connected': any(n.get('text') == 'ACTIVE · CONNECTED' for n in nodes),
               'offline': any(n.get('content-desc') == 'Push to talk, OFFLINE' for n in nodes),
               'reconnecting': any(n.get('text') == 'ACTIVE · RECONNECTING' for n in nodes)}
        rows.append(row)
        (args.output_dir / 'results.json').write_text(json.dumps(rows, indent=2))
        print(json.dumps(row), flush=True)
        return row

    before = capture('before')
    if not before['ready'] or not before['connected']:
        raise RuntimeError('App must be visible, POWER ON and READY before testing')
    try:
        adb('shell', 'cmd', 'connectivity', 'airplane-mode', 'enable')
        adb('shell', 'svc', 'wifi', 'disable')
        time.sleep(12)
        offline = capture('offline')
    finally:
        # Try both restores even if the first command fails.
        try:
            adb('shell', 'cmd', 'connectivity', 'airplane-mode', 'disable')
        finally:
            adb('shell', 'svc', 'wifi', 'enable')
    time.sleep(12)
    restored = capture('restored12s')
    if not restored['ready'] or not restored['connected']:
        time.sleep(18)
        restored = capture('restored30s')
    if not offline['offline'] or not offline['reconnecting']:
        raise RuntimeError('Network-loss UI was not observed; result is inconclusive')
    if not restored['ready'] or not restored['connected']:
        raise RuntimeError('Automatic READY recovery was not observed')
    print('UI_RECOVERY_PASS (audio and subsequent PTT unverified)', flush=True)


if __name__ == '__main__':
    main()
