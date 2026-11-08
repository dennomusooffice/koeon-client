#!/usr/bin/env python3
"""Loopback-only BATv1 wire fixture. Synthetic PCM only; not a production backend."""
import argparse, json, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
generations = {}
attempts = {}
results = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        try: self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        if self.path == '/lab/status':
            with lock: self.reply(200, {'generations': sorted(generations), 'attempts': dict(attempts), 'results': list(results)})
        else: self.reply(404, {})
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size > 200000: return self.reply(413, {})
        try: data = json.loads(self.rfile.read(size))
        except ValueError: return self.reply(400, {})
        if self.path == '/api/audio/batv1/subscribe' and data.get('generationId') == 'lab-stalled':
            with lock:
                key = data['sessionId'] + ':lab-stalled'
                attempts[key] = attempts.get(key, 0) + 1
            time.sleep(5)
            return self.reply(503, {'error': {'code': 'LAB_STALLED', 'message': 'synthetic stall'}})
        with lock:
            if self.path == '/lab/result':
                results.append(data)
                return self.reply(200, {'ok': True})
            generation = data.get('generationId', '')
            if self.path == '/api/audio/batv1/publish':
                chunks = data['chunks']
                generations[generation] = data
                return self.reply(200, {'outcome': 'accepted', 'acceptedChunks': len(chunks), 'latestSequence': chunks[-1]['sequence']})
            if self.path != '/api/audio/batv1/subscribe': return self.reply(404, {})
            key = data['sessionId'] + ':' + generation
            attempts[key] = attempts.get(key, 0) + 1
            attempt = attempts[key]
            if generation not in generations or ('transient' in generation and attempt <= 2):
                return self.reply(503, {'error': {'code': 'LAB_RETRY', 'message': 'synthetic outage'}})
            if 'transient' in generation and attempt == 3:
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            tx = generations[generation]
            first = 28 if 'expired' in generation else 0
            cursor = data['nextSequence']
            chunks = [c for c in tx['chunks'] if c['sequence'] >= max(first, cursor)][:8]
            nxt = chunks[-1]['sequence'] + 1 if chunks else max(first, cursor)
            return self.reply(200, dict(protocolVersion=1, generationId=generation, codec='pcm16le',
                sampleRate=48000, channels=1, frameDurationMs=20, firstAvailableSequence=first,
                latestSequence=31, nextSequence=nxt, finalSequence=31, bufferHeadExpired=cursor < first,
                timelineEnded=nxt > 31, chunks=chunks))

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    print('LAB_READY loopback:' + str(args.port), flush=True)
    server.serve_forever()
