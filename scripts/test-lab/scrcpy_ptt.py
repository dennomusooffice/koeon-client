"""Control-only scrcpy transport for authorized, bounded physical PTT trials.

No video/audio stream or clipboard synchronization. The caller owns the device,
current display geometry, safe initialization point, test window and observations.
An injected event is never reported as successful transmission or audio delivery.
"""
import hashlib
import math
import secrets
import socket
import struct
import subprocess
import threading
import time
from pathlib import Path

VERSION = '5.0.1'
SERVER_SHA256 = '764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536'


def touch_packet(action, x, y, width, height):
    if action not in (0, 1, 2) or isinstance(action, bool):
        raise ValueError('unsupported touch action')
    if any(isinstance(v, bool) or not isinstance(v, int) for v in (x, y, width, height)):
        raise ValueError('integer display coordinates required')
    if not (0 < width <= 16384 and 0 < height <= 16384 and 0 <= x < width and 0 <= y < height):
        raise ValueError('point outside current display')
    return struct.pack('>BBQiiHHHii', 2, action, 0, x, y, width, height,
                       0 if action == 1 else 65535, 0, 0)


class ScrcpyTouch:
    def __init__(self, adb, serial, server, width, height, expires_at, log):
        if not isinstance(serial, str) or not serial or serial.startswith('-'):
            raise ValueError('explicit serial required')
        touch_packet(0, 0, 0, width, height)
        if not math.isfinite(expires_at) or not time.time() < expires_at <= time.time() + 4 * 3600:
            raise ValueError('future testing deadline within four hours required')
        self.adb, self.serial, self.server = adb, serial, Path(server)
        self.width, self.height, self.expires_at, self.log = width, height, expires_at, log
        self.sock = self.proc = self.port = self.remote = None
        self.active = None
        self.lock = threading.RLock()

    def command(self, *args):
        return subprocess.check_output([self.adb, '-s', self.serial, *args], timeout=15, text=True).strip()

    def __enter__(self):
        if hashlib.sha256(self.server.read_bytes()).hexdigest() != SERVER_SHA256:
            raise ValueError('server checksum mismatch')
        self._within_window()
        scid = secrets.randbits(31)
        self.remote = '/data/local/tmp/koeon-input-' + format(scid, '08x') + '.jar'
        try:
            self.command('push', str(self.server), self.remote)
            self.port = int(self.command('forward', 'tcp:0', 'localabstract:scrcpy_' + format(scid, '08x')))
            self.proc = subprocess.Popen([self.adb, '-s', self.serial, 'shell', 'CLASSPATH=' + self.remote,
                'app_process', '/', 'com.genymobile.scrcpy.Server', VERSION,
                'scid=' + format(scid, 'x'), 'log_level=warn', 'video=false', 'audio=false',
                'control=true', 'tunnel_forward=true', 'send_device_meta=false', 'send_dummy_byte=true',
                'clipboard_autosync=false', 'power_on=false', 'cleanup=false'], stdout=self.log, stderr=self.log)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                candidate = None
                try:
                    candidate = socket.create_connection(('127.0.0.1', self.port), timeout=1)
                    if candidate.recv(1) == b'\0':
                        self.sock = candidate
                        self.sock.settimeout(2)
                        return self
                except OSError:
                    pass
                finally:
                    if candidate is not None and candidate is not self.sock:
                        candidate.close()
                time.sleep(.1)
            raise TimeoutError('control handshake unavailable')
        except BaseException:
            self.close()
            raise

    def _within_window(self):
        if time.time() >= self.expires_at:
            raise TimeoutError('physical testing window expired')

    def touch(self, action, x, y):
        packet = touch_packet(action, x, y, self.width, self.height)
        with self.lock:
            if action != 1:
                self._within_window()
            if self.sock is None:
                raise RuntimeError('control connection absent')
            # Record DOWN before sending so a partial send still gets an UP attempt.
            if action != 1:
                self.active = (x, y)
            self.sock.sendall(packet)
            if action == 1:
                self.active = None

    def initialize_at(self, x, y):
        """Caller must visually verify a non-action area; never prime on PTT.

        Xiaomi first-gesture loss is a device observation, not a universal rule.
        Keep this opt-in, and independently observe the subsequent real gesture.
        """
        try:
            self.touch(0, x, y)
            time.sleep(.1)
        finally:
            self.touch(1, x, y)

    def hold(self, x, y, seconds, observe):
        if isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or not 1 <= seconds <= 10:
            raise ValueError('hold duration must be 1..10 seconds')
        if time.time() + seconds + 2 >= self.expires_at:
            raise TimeoutError('insufficient time to release before deadline')
        errors = []
        def release():
            try:
                self.touch(1, x, y)
            except Exception as exc:
                errors.append(type(exc).__name__)
        timer = threading.Timer(seconds, release)
        started = time.monotonic()
        try:
            self.touch(0, x, y)
            timer.start()
            time.sleep(min(2, seconds / 2))
            evidence = observe()  # Passive and bounded by the caller; never UIAutomator.
            time.sleep(max(0, seconds - (time.monotonic() - started)))
        finally:
            timer.cancel()
            if timer.ident is not None:
                timer.join(timeout=3)
            release()
        if errors:
            raise RuntimeError('touch release failed; stop trial and inspect device')
        return {'status': 'OBSERVATION_REQUIRED', 'evidence': evidence, 'audioAcceptance': 'NOT_ESTABLISHED'}

    def close(self):
        errors = []
        if self.sock is not None:
            try:
                if self.active is not None:
                    self.touch(1, *self.active)
            except Exception:
                errors.append('UP')
            finally:
                self.sock.close()
                self.sock = None
        if self.proc is not None:
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=3)
            self.proc = None
        for args in ([('forward', '--remove', 'tcp:' + str(self.port))] if self.port else []) + ([('shell', 'rm', '-f', self.remote)] if self.remote else []):
            try:
                self.command(*args)
            except Exception:
                errors.append(args[0])
        self.port = self.remote = None
        if errors:
            raise RuntimeError('control cleanup incomplete: ' + ','.join(errors))

    def __exit__(self, *args):
        self.close()
