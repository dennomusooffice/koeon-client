#!/usr/bin/env python3
"""SIM5 bounded control runner. Real devices are deliberately excluded; see STANDARD.md for mixed runs."""
import argparse
import concurrent.futures
from datetime import datetime, timezone
import json
import plistlib
import hashlib
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.request
import xml.etree.ElementTree as ET


def command(args, timeout=45, check=True, env=None):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=check, env=env).stdout.strip()

class EndpointNotReady(RuntimeError):
    def __init__(self, alias):
        super().__init__('PTT control unavailable'); self.alias = alias

class Lab:
    def __init__(self, config, output):
        self.c = json.loads(Path(config).read_text()); self.out = Path(output)
        self.out.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.sdk = Path(self.c['androidSdk']).expanduser()
        self.adb = str(self.sdk / 'platform-tools/adb')
        self.android = {d['alias']: d for d in self.c['android']}
        self.ios = self.c['ios']; self.keys = list(self.android) + [self.ios['alias']]
        if sorted(d['api'] for d in self.android.values()) != [34, 35, 36, 37] or len(set(self.keys)) != 5:
            raise ValueError('SIM5 requires four distinct Android API34–37 and one iOS alias')
        for alias in self.keys:
            if not re.fullmatch(r'[a-zA-Z0-9_-]{1,32}', alias): raise ValueError('invalid alias')
        if not self.c['appium'].startswith('http://127.0.0.1:'): raise ValueError('Appium must be local')
        # Confirm the requested identifier belongs to a Simulator, never a physical iPhone.
        available = json.loads(command(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
        if not any(d['udid'] == self.ios['udid'] for ds in available.values() for d in ds):
            raise ValueError('iOS identifier is not an available Simulator')
        self.session = None
    def save(self, name, value):
        (self.out / name).write_text(json.dumps(value, indent=2) + '\n')
    def adbcall(self, alias, *args, **kw):
        d = self.android[alias]
        return command([self.adb, '-s', f"emulator-{d['port']}", *args], **kw)
    def api(self, path, data=None, method=None, timeout=60):
        request = urllib.request.Request(self.c['appium'] + path,
            data=None if data is None else json.dumps(data).encode(), headers={'Content-Type': 'application/json'}, method=method)
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.load(response)['value']
        if isinstance(value, dict) and value.get('error'): raise RuntimeError(value['error'])
        return value
    def ui_session(self):
        if self.session: return
        saved = self.out / 'ios-ui-session.json'
        if saved.exists():
            sid = json.loads(saved.read_text())['sessionId']
            try:
                self.api('/session/' + sid + '/source'); self.session = sid; return
            except Exception:
                try: self.api('/session/' + sid, method='DELETE')
                except Exception: pass
        value = self.api('/session', {'capabilities': {'alwaysMatch': {
            'platformName': 'iOS', 'appium:automationName': 'XCUITest', 'appium:udid': self.ios['udid'],
            'appium:deviceName': 'KOEON simulator', 'appium:bundleId': self.c['iosApp'],
            'appium:noReset': True, 'appium:autoLaunch': False, 'appium:shouldTerminateApp': False,
            'appium:newCommandTimeout': 3600, 'appium:wdaLocalPort': self.ios.get('wdaPort', 8104)
        }}}, timeout=120)
        self.session = value['sessionId']; self.save('ios-ui-session.json', {'sessionId': self.session})
    def inventory(self):
        result = {'utc': datetime.now(timezone.utc).isoformat(), 'sha': command(['git', 'rev-parse', 'HEAD']),
            'dirty': bool(command(['git', 'status', '--porcelain'])), 'xcode': command(['xcodebuild', '-version']),
            'macOS': command(['sw_vers']), 'emulator': command([str(self.sdk/'emulator/emulator'), '-version']).splitlines()[:2],
            'avds': command([str(self.sdk/'emulator/emulator'), '-list-avds']).splitlines(), 'endpoints': {}}
        for k, d in self.android.items():
            try:
                version = self.adbcall(k, 'shell', 'getprop', 'ro.build.version.sdk')
                package = self.adbcall(k, 'shell', 'dumpsys', 'package', self.c['androidApp'])
                result['endpoints'][k] = {'api': version, 'versions': re.findall(r'version(?:Code|Name)=[^\s]+', package)}
            except Exception as error: result['endpoints'][k] = {'status': 'NOT_READY', 'error': type(error).__name__}
        try:
            app = Path(command(['xcrun', 'simctl', 'get_app_container', self.ios['udid'], self.c['iosApp'], 'app']))
            info = plistlib.loads((app / 'Info.plist').read_bytes())
            binary = app / info['CFBundleExecutable']
            result['endpoints'][self.ios['alias']] = {'version': info['CFBundleShortVersionString'],
                'build': info['CFBundleVersion'], 'executableSha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'linkedEntitlements': '__entitlements' in command(['otool', '-l', str(binary)])}
        except Exception as error:
            result['endpoints'][self.ios['alias']] = {'status': 'NOT_READY', 'error': type(error).__name__}
        self.save('inventory.json', result)
        print(json.dumps({'inventory': str(self.out / 'inventory.json')}), flush=True)
    def boot(self):
        command(['xcrun', 'simctl', 'boot', self.ios['udid']], check=False)
        command(['xcrun', 'simctl', 'bootstatus', self.ios['udid'], '-b'], timeout=120)
        command(['xcrun', 'simctl', 'launch', '--terminate-running-process', self.ios['udid'], self.c['iosApp']],
            env=dict(os.environ, SIMCTL_CHILD_KOEON_SIMULATOR_FOREGROUND='1'))
        self.ui_session()
        for alias, d in self.android.items():
            try: ready = self.adbcall(alias, 'shell', 'getprop', 'sys.boot_completed', timeout=10) == '1'
            except Exception: ready = False
            if not ready:
                with (self.out / (alias + '-emulator.log')).open('a') as log:
                    proc = subprocess.Popen([str(self.sdk/'emulator/emulator'), '-avd', d['avd'], '-port', str(d['port']),
                        '-no-window', '-no-boot-anim', '-no-snapshot', '-memory', '1536', '-cores', '2',
                        '-grpc', str(d['port']+3000), '-grpc-use-token'], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    if proc.poll() is not None: raise RuntimeError(alias + ' emulator exited')
                    try:
                        if self.adbcall(alias, 'shell', 'getprop', 'sys.boot_completed', timeout=10) == '1': break
                    except Exception: pass
                    time.sleep(2)
                else: raise TimeoutError(alias + ' boot')
            # boot_completed may precede ActivityManager readiness; bounded retry only.
            for attempt in range(5):
                try:
                    self.adbcall(alias, 'shell', 'am', 'start', '-n', self.c['androidApp'] + '/.MainActivity')
                    break
                except subprocess.CalledProcessError:
                    if attempt == 4: raise
                    time.sleep(2)
            print(alias + ' booted; enrollment/power preserved', flush=True)
    def ready(self):
        """POWER ON only on enrolled Simulator screens; never enter credentials."""
        self.ui_session()
        for alias in self.keys:
            if alias in self.android:
                self.adbcall(alias, 'shell', 'uiautomator', 'dump', '/sdcard/koeon-test-lab.xml')
                xml = self.adbcall(alias, 'exec-out', 'cat', '/sdcard/koeon-test-lab.xml')
                nodes = list(ET.fromstring(xml).iter('node'))
                button = next((n for n in nodes if n.get('text', '').startswith('POWER ON')), None)
                if button is not None:
                    bounds = list(map(int, re.findall(r'\d+', button.get('bounds'))))
                    self.adbcall(alias, 'shell', 'input', 'tap', str((bounds[0]+bounds[2])//2), str((bounds[1]+bounds[3])//2))
            else:
                path = '/session/' + self.session
                xml = self.api(path + '/source')
                if any(n.get('name') == 'POWER ON · START' for n in ET.fromstring(xml).iter()):
                    element = self.api(path + '/element', {'using': 'accessibility id', 'value': 'POWER ON · START'})
                    identifier = element.get('element-6066-11e4-a52e-4f735466cecf') or element['ELEMENT']
                    self.api(path + '/element/' + identifier + '/click', {})
            (self.out / ('ready-entry-' + alias + '.xml')).write_text(xml)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                states = self.states(self.keys, 'ready-check')
                if all(v['ptt']=='READY' and v['enabled'] for v in states.values()):
                    self.save('ready.json', states); print('SIM5 READY', flush=True); return
            except EndpointNotReady:
                pass
            time.sleep(2)
        raise RuntimeError('SIM5 not READY; preserve evidence and inspect, no reset performed')

    def snapshot(self, alias, stage):
        if alias in self.android:
            self.adbcall(alias, 'shell', 'uiautomator', 'dump', '/sdcard/koeon-test-lab.xml')
            xml = self.adbcall(alias, 'exec-out', 'cat', '/sdcard/koeon-test-lab.xml')
            nodes = ET.fromstring(xml).iter('node')
            (self.out / (stage + '-' + alias + '.xml')).write_text(xml)
            node = next((n for n in nodes if n.get('content-desc', '').startswith('Push to talk,')), None)
            if node is None: raise EndpointNotReady(alias)
            bounds = list(map(int, re.findall(r'\d+', node.get('bounds'))))
            value = {'ptt': node.get('content-desc').split(', ', 1)[1].replace(' ', '_'),
                'enabled': node.get('enabled') == 'true', 'x': (bounds[0]+bounds[2])//2, 'y': (bounds[1]+bounds[3])//2}
        else:
            xml = self.api('/session/' + self.session + '/source')
            (self.out / (stage + '-' + alias + '.xml')).write_text(xml)
            node = next((n for n in ET.fromstring(xml).iter() if n.get('name') == 'Push to talk'), None)
            if node is None: raise EndpointNotReady(alias)
            value = {'ptt': node.get('value'), 'enabled': node.get('enabled') == 'true',
                'x': int(float(node.get('x'))+float(node.get('width'))/2), 'y': int(float(node.get('y'))+float(node.get('height'))/2)}
        (self.out / (stage + '-' + alias + '.xml')).write_text(xml)
        return value
    def states(self, keys, stage):
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            return dict(zip(keys, pool.map(lambda k: self.snapshot(k, stage), keys)))
    def press(self, alias, value, milliseconds=20000):
        x, y = value['x'], value['y']
        if alias in self.android:
            return self.adbcall(alias, 'shell', 'input', 'swipe', str(x), str(y), str(x), str(y), str(milliseconds))
        return self.api('/session/' + self.session + '/actions', {'actions': [{'type': 'pointer', 'id': 'finger',
            'parameters': {'pointerType': 'touch'}, 'actions': [{'type': 'pointerMove', 'duration': 0, 'x': x, 'y': y},
            {'type': 'pointerDown', 'button': 0}, {'type': 'pause', 'duration': milliseconds}, {'type': 'pointerUp', 'button': 0}]}]})
    def controls(self, rounds, senders=None):
        self.ui_session(); results = []
        senders = senders or self.keys
        if not senders or any(k not in self.keys for k in senders): raise ValueError("unknown sender alias")
        try:
            for round_ in range(1, rounds+1):
                for sender in senders:
                    case = f'CTRL-{round_}-{sender}'
                    row = {'case': case, 'sender': sender, 'startedAt': datetime.now(timezone.utc).isoformat(), 'audioInjected': False, 'startedMonotonicMs': int(time.monotonic()*1000)}
                    try:
                        row['before'] = self.states(self.keys, case+'-before')
                        if not all(v['ptt']=='READY' and v['enabled'] for v in row['before'].values()):
                            row['status'] = 'BLOCKED'; raise RuntimeError('preflight not READY')
                        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                            sending = pool.submit(self.press, sender, row['before'][sender]); time.sleep(3)
                            row['during'] = self.states([k for k in self.keys if k != sender], case+'-during')
                            active = not sending.done(); sending.result(timeout=30)
                        time.sleep(2); row['after'] = self.states(self.keys, case+'-after')
                        row['status'] = 'PASS' if active and all(v['ptt']=='BUSY_REMOTE' for v in row['during'].values()) and all(v['ptt']=='READY' for v in row['after'].values()) else 'PRODUCT_FAIL'
                    except Exception as error:
                        row.setdefault('status', 'BLOCKED' if isinstance(error, EndpointNotReady) else 'ENV_FAIL')
                        row['errorClass'] = type(error).__name__
                        if isinstance(error, EndpointNotReady): row['failedEndpoint'] = error.alias
                    row['endedAt'] = datetime.now(timezone.utc).isoformat(); row['endedMonotonicMs'] = int(time.monotonic()*1000); results.append(row)
                    self.save('control-results.json', results); print(case, row['status'], flush=True)
                    if row['status'] != 'PASS': return False
        finally:
            if self.session:
                try: self.api('/session/' + self.session + '/actions', method='DELETE')
                except Exception: pass
        return True
    def shutdown(self):
        for k in self.android:
            self.adbcall(k, 'emu', 'kill', check=False)
        command(['xcrun', 'simctl', 'shutdown', self.ios['udid']], check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['inventory', 'boot', 'ready', 'control', 'shutdown'])
    parser.add_argument('--config', default='.secret/test-lab/config.json')
    parser.add_argument('--output', required=True, help='private run directory (same for boot/control)')
    parser.add_argument('--rounds', type=int, choices=[1, 2, 3], default=3)
    parser.add_argument('--senders', help='optional comma-separated subset/order of configured aliases')
    args = parser.parse_args(); os.umask(0o077)
    lab = Lab(args.config, args.output)
    if args.action == 'control': raise SystemExit(0 if lab.controls(args.rounds, args.senders.split(',') if args.senders else None) else 1)
    getattr(lab, args.action)()

if __name__ == '__main__': main()
