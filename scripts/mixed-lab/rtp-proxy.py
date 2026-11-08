#!/usr/bin/env python3
"""Loopback-only LiveKit lab: per-device shared 128kbps full-duplex TCP budget.

Both signaling and ICE/TCP consume the SAME budget for each device/direction.
TCP/IP overhead is not counted: this is an application-byte limit, not a SIM model.
No production credentials or audio files are read/written.
"""
import asyncio
import base64
import hashlib
import hmac
import json
import time

KEY = 'koeon-local-lab'
SECRET = 'koeon-local-lab-only-not-a-production-secret'


class Budget:
    def __init__(self):
        self.next = 0.0
        self.bytes = 0
        self.started = time.monotonic()

    async def transfer(self, count):
        now = time.monotonic()
        self.next = max(now, self.next) + count / 16000
        await asyncio.sleep(max(0, self.next - now))
        self.bytes += count


def token(role):
    def enc(value):
        return base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).rstrip(b'=')
    now = int(time.time())
    body = enc({'alg': 'HS256', 'typ': 'JWT'}) + b'.' + enc({
        'iss': KEY, 'sub': role, 'nbf': now - 10, 'exp': now + 3600,
        'video': {'roomJoin': True, 'room': 'koeon-local-lab', 'canPublish': True,
                  'canSubscribe': True, 'canPublishData': True}})
    return (body + b'.' + base64.urlsafe_b64encode(hmac.new(SECRET.encode(), body, hashlib.sha256).digest()).rstrip(b'=')).decode()


async def main():
    budgets = {role: [Budget(), Budget()] for role in ('android35', 'android36')}
    results = []

    async def proxy(reader, writer, port, pair):
        remote_writer = None
        tasks = []
        try:
            remote_reader, remote_writer = await asyncio.open_connection('127.0.0.1', port)

            async def pipe(source, target, budget):
                while data := await source.read(512):
                    await budget.transfer(len(data))
                    target.write(data)
                    await target.drain()
            tasks = [asyncio.create_task(pipe(reader, remote_writer, pair[0])),
                     asyncio.create_task(pipe(remote_reader, writer, pair[1]))]
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (ConnectionError, OSError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            writer.close()
            if remote_writer:
                remote_writer.close()

    async def status(reader, writer):
        try:
            headers = await reader.readuntil(b'\r\n\r\n')
            path = headers.split(b' ')[1].decode()
            if path.startswith('/token/'):
                role = path.rsplit('/', 1)[1]
                assert role in (*budgets, 'ios27')
                response = {'token': token(role)}
            elif path == '/result':
                length = next(int(line.split(b':')[1]) for line in headers.split(b'\r\n') if line.lower().startswith(b'content-length:'))
                assert length <= 4096
                results.append(json.loads(await reader.readexactly(length)))
                response = {'ok': True}
            else:
                response = {'results': results, 'budgets': {role: [
                    {'bytes': b.bytes, 'elapsed': time.monotonic() - b.started} for b in pair
                ] for role, pair in budgets.items()}}
            data = json.dumps(response).encode()
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ' + str(len(data)).encode() + b'\r\n\r\n' + data)
            await writer.drain()
        finally:
            writer.close()

    servers = [await asyncio.start_server(status, '127.0.0.1', 18766)]
    for role, base in [('android35', 18180), ('android36', 18280)]:
        for offset, destination in [(0, 19080), (1, 19081)]:
            servers.append(await asyncio.start_server(
                lambda r, w, d=destination, p=budgets[role]: proxy(r, w, d, p), '127.0.0.1', base + offset))
    await asyncio.gather(*(server.serve_forever() for server in servers))


if __name__ == '__main__':
    asyncio.run(main())
