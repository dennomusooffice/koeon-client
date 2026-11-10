import importlib.util
import io
import pathlib
import struct
import time
import unittest
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('scrcpy_ptt', pathlib.Path(__file__).parents[1] / 'scrcpy_ptt.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class Socket:
    def __init__(self): self.frames = []
    def sendall(self, frame): self.frames.append(struct.unpack('>BBQiiHHHii', frame))
    def close(self): pass

class ControlTests(unittest.TestCase):
    def client(self):
        c = m.ScrcpyTouch('adb', 'test-device', 'unused', 1080, 2400, time.time()+60, io.BytesIO())
        c.sock = Socket()
        return c
    def test_observer_exception_releases_pointer(self):
        c = self.client()
        def fail(): raise RuntimeError('observer failed')
        with patch.object(m.time, 'sleep'), self.assertRaisesRegex(RuntimeError, 'observer failed'):
            c.hold(500, 1000, 2, fail)
        self.assertEqual([f[1] for f in c.sock.frames], [0, 1])
        self.assertIsNone(c.active)
    def test_window_expiry_blocks_down_but_allows_release(self):
        c = self.client(); c.touch(0, 1, 1); c.expires_at = time.time()-1
        with self.assertRaises(TimeoutError): c.touch(0, 1, 1)
        c.touch(1, 1, 1)
        self.assertEqual([f[1] for f in c.sock.frames], [0, 1])
    def test_invalid_duration_and_coordinates_never_send(self):
        c = self.client()
        for duration in [0, 11, True, float('inf'), float('nan')]:
            with self.assertRaises(ValueError): c.hold(1, 1, duration, lambda: None)
        for coords in [(-1, 0), (1080, 0), (0, 2400), (True, 0)]:
            with self.assertRaises(ValueError): c.touch(0, *coords)
        self.assertEqual(c.sock.frames, [])
    def test_close_releases_active_pointer(self):
        c = self.client(); sock = c.sock; c.touch(0, 1, 1); c.close()
        self.assertEqual([f[1] for f in sock.frames], [0, 1])
    def test_unknown_server_is_rejected_before_device_access(self):
        import tempfile
        with tempfile.NamedTemporaryFile() as f:
            f.write(b'not the pinned server'); f.flush()
            c = self.client(); c.server = pathlib.Path(f.name)
            with patch.object(c, 'command') as command, self.assertRaisesRegex(ValueError, 'checksum'):
                c.__enter__()
            command.assert_not_called()

if __name__ == '__main__': unittest.main()
