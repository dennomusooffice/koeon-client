#!/usr/bin/env python3
"""Fetch an already exported journal from ONE explicitly selected endpoint; never unlock/reset/re-register."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
from collect import load_bundle

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('kind', choices=['ios-sim', 'ios-device', 'android-debug', 'android-file'])
    p.add_argument('--device', required=True, help='explicit simulator UDID or device serial/identifier')
    p.add_argument('--app', default='org.example.koeon')
    p.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
    p.add_argument('--remote', help='Android SAF-saved /sdcard/... file for android-file')
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args(); os.umask(0o077)
    if a.output.exists(): p.error('output already exists; preserve previous evidence')
    a.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = a.output.with_name(a.output.name + '.partial')
    if temporary.exists(): p.error('partial output exists')
    try:
        if a.kind == 'ios-sim':
            container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', a.device, a.app, 'data'], text=True).strip()
            shutil.copyfile(Path(container) / 'Library/Caches/KOEONDiagnostics/field-journal-export.json', temporary)
        elif a.kind == 'ios-device':
            subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', a.device,
                '--domain-type', 'appDataContainer', '--domain-identifier', a.app,
                '--source', 'Library/Caches/KOEONDiagnostics/field-journal-export.json', '--destination', str(temporary)], check=True, timeout=60)
        elif a.kind == 'android-debug':
            with temporary.open('xb') as out:
                subprocess.run([a.adb, '-s', a.device, 'exec-out', 'run-as', a.app, 'cat',
                    'files/KOEONDiagnostics/field-journal-export.json'], stdout=out, check=True, timeout=60)
        else:
            if not a.remote or not a.remote.startswith('/sdcard/') or '..' in Path(a.remote).parts:
                p.error('android-file requires explicit SAF-saved /sdcard/... path')
            subprocess.run([a.adb, '-s', a.device, 'pull', a.remote, str(temporary)], check=True, timeout=60)
        bundle = load_bundle(temporary)
        temporary.chmod(0o600); temporary.rename(a.output)
        print(json.dumps(dict(exportedAtMs=bundle['manifest'].get('exportedAtMs'),
            records=len(bundle['records']), sha256=hashlib.sha256(a.output.read_bytes()).hexdigest(), output=str(a.output))))
    finally:
        temporary.unlink(missing_ok=True)

if __name__ == '__main__': main()
