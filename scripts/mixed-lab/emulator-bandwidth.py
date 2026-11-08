#!/usr/bin/env python3
"""Run a bounded command with measured-path-compatible AVD traffic shaping.

Requires an already-rooted debuggable AVD. Never accepts physical serials.
Only default root qdiscs and an unused ifb0 are accepted. Existing Android
clsact/BPF filters are retained; our exact filter priority is removed on exit.
All protocol traffic on eth0/wlan0 shares the inbound 128 kbit/s IFB; each
outbound interface is capped at 128 kbit/s (not a cross-interface aggregate).
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--evidence-dir', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not re.fullmatch(r'emulator-\d+', args.serial) or not command or not 1 <= args.timeout <= 1800:
        parser.error('An emulator serial, command, and timeout of 1..1800 are required')
    os.umask(0o077)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)

    def shell(*values):
        return subprocess.check_output([args.adb, '-s', args.serial, 'shell', *values],
                                       text=True, timeout=20).strip()

    if shell('getprop', 'ro.kernel.qemu') != '1' or 'uid=0(root)' not in shell('id'):
        raise RuntimeError('Requires a debuggable, already-rooted Android emulator')
    before = shell('tc', 'qdisc', 'show')
    ifb = shell('ip', 'link', 'show', 'ifb0')
    if 'state DOWN' not in ifb:
        raise RuntimeError('ifb0 is not unused/down')
    for dev in ('eth0', 'wlan0'):
        lines = [line for line in before.splitlines() if f'dev {dev} root' in line]
        if len(lines) != 1 or lines[0].split()[1] not in ('mq', 'pfifo_fast', 'noqueue'):
            raise RuntimeError('Refusing to replace a non-default root qdisc')
        filters = shell('tc', 'filter', 'show', 'dev', dev, 'ingress')
        (args.evidence_dir / (dev + '-filters-before.txt')).write_text(filters)
        if 'pref 49152' in filters:
            raise RuntimeError('Reserved probe filter priority is already in use')
        if not any(f'dev {dev} ' in line and 'qdisc clsact ' in line for line in before.splitlines()):
            raise RuntimeError('Expected existing Android clsact qdisc')
    if any('dev ifb0 ' in line and line.split()[1] not in ('pfifo_fast', 'noqueue')
           for line in before.splitlines()):
        raise RuntimeError('ifb0 already has a non-default qdisc')
    (args.evidence_dir / 'qdisc-before.txt').write_text(before)
    roots, filters, failures = [], [], []
    code = 1

    def terminate(_signal, _frame):
        raise KeyboardInterrupt('Termination requested; restoring AVD networking')

    signal.signal(signal.SIGTERM, terminate)
    try:
        shell('ip', 'link', 'set', 'ifb0', 'up')
        for dev in ('ifb0', 'eth0', 'wlan0'):
            shell('tc', 'qdisc', 'replace', 'dev', dev, 'root', 'handle', '7a00:',
                  'tbf', 'rate', '128kbit', 'burst', '8kb', 'latency', '1000ms')
            roots.append(dev)
        for dev in ('eth0', 'wlan0'):
            shell('tc', 'filter', 'add', 'dev', dev, 'ingress', 'pref', '49152',
                  'matchall', 'action', 'mirred', 'egress', 'redirect', 'dev', 'ifb0')
            filters.append(dev)
        (args.evidence_dir / 'qdisc-active.txt').write_text(shell('tc', 'qdisc', 'show'))
        # Popen context kills/waits its child on TimeoutExpired only when explicitly handled.
        with subprocess.Popen(command) as child:
            try:
                code = child.wait(timeout=args.timeout)
            except BaseException:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                raise
    finally:
        try:
            (args.evidence_dir / 'qdisc-stats.txt').write_text(shell('tc', '-s', 'qdisc', 'show'))
        except Exception:
            failures.append('stats capture')
        for dev in filters:
            try:
                shell('tc', 'filter', 'del', 'dev', dev, 'ingress', 'pref', '49152')
            except Exception:
                failures.append('filter removal: ' + dev)
        for dev in roots:
            try:
                shell('tc', 'qdisc', 'del', 'dev', dev, 'root')
            except Exception:
                failures.append('root qdisc removal: ' + dev)
        try:
            shell('ip', 'link', 'set', 'ifb0', 'down')
            after = shell('tc', 'qdisc', 'show')
            (args.evidence_dir / 'qdisc-after.txt').write_text(after)
            if '7a00:' in after:
                failures.append('probe qdisc remains')
        except Exception:
            failures.append('final restore verification')
        (args.evidence_dir / 'result.json').write_text(json.dumps(
            {'commandExitCode': code, 'cleanupFailures': failures,
             'rateKbit': 128, 'burst': '8kb', 'queueLatencyMs': 1000}, indent=2))
        if failures:
            raise RuntimeError('AVD cleanup incomplete; inspect private result.json')
    raise SystemExit(code)


if __name__ == '__main__':
    main()
