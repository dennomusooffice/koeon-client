#!/usr/bin/env python3
"""Measure synthetic TCP payload through an AVD network path (no adb reverse).

Use inside emulator-bandwidth.py. This tests the 10.0.2.2 host path, not an
Internet server, carrier throughput, or UDP quality. Saves numbers only.
"""
import argparse
import json
from pathlib import Path
import re
import socket
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.serial):
        parser.error('Only an emulator serial is supported')
    if subprocess.check_output([args.adb, '-s', args.serial, 'shell', 'getprop', 'ro.kernel.qemu'], text=True).strip() != '1':
        raise RuntimeError('Not an emulator')
    rows = []
    size = 256 * 1024
    for direction in ('download', 'upload'):
        server = socket.socket()
        server.bind(('127.0.0.1', 0))
        server.listen(1)
        server.settimeout(10)
        port = server.getsockname()[1]
        observed = {}

        def serve():
            try:
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(55)
                    if direction == 'download':
                        connection.sendall(bytes(size))
                        observed['bytes'] = size
                    else:
                        total = 0
                        while total < size:
                            data = connection.recv(min(65536, size-total))
                            if not data:
                                break
                            total += len(data)
                        observed['bytes'] = total
            except Exception as error:
                observed['error'] = type(error).__name__
            finally:
                server.close()

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        command = (f'nc -w 5 -W 45 10.0.2.2 {port} < /dev/null | wc -c' if direction == 'download'
                   else f'head -c {size} /dev/zero | nc -w 5 -W 45 10.0.2.2 {port}')
        start = time.monotonic()
        try:
            result = subprocess.run([args.adb, '-s', args.serial, 'shell', command],
                                    capture_output=True, text=True, timeout=55, check=True)
            elapsed = time.monotonic() - start
            thread.join(timeout=3)
            received = int(result.stdout.strip()) if direction == 'download' else observed.get('bytes', 0)
            rate = received * 8 / elapsed / 1000
            row = {'direction': direction, 'bytes': received, 'elapsedSeconds': elapsed,
                   'payloadKbps': rate, 'serverError': observed.get('error'),
                   'withinCalibrationRange': received == size and 70 <= rate <= 145 and not observed.get('error')}
            rows.append(row)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(rows, indent=2))
            print(json.dumps(row), flush=True)
        finally:
            server.close()
    if not all(row['withinCalibrationRange'] for row in rows):
        raise SystemExit('128 kbit/s calibration failed; do not claim bandwidth-constrained acceptance')


if __name__ == '__main__':
    main()
