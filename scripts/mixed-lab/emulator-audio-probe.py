#!/usr/bin/env python3
"""Measure production KOEON audio via authenticated Android Emulator gRPC.

Requires generated emulator_controller_pb2{,_grpc}, grpcio and numpy. Use only
synthetic speech as --source. Receiver PCM is analyzed in memory, never saved.
This measures signal arrival, not human intelligibility or end-to-end latency.
"""
import argparse
import concurrent.futures
import json
import itertools
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
import wave
import xml.etree.ElementTree as ET

import grpc
import numpy as np
from google.protobuf.empty_pb2 import Empty


def correlation(samples, template):
    audio = np.asarray(samples, dtype=float)[::6]
    target = template.astype(float)[::6]
    target -= target.mean()
    if len(audio) < len(target) or not np.dot(target, target):
        return {'correlation': 0., 'reversedControlCorrelation': 0., 'phaseControlCorrelation': 0., 'orderedSpeechSegments': False}
    count = 1 << (len(audio) + len(target) - 1).bit_length()
    energy = np.concatenate(([0.], np.cumsum(audio * audio)))
    window_energy = energy[len(target):] - energy[:-len(target)]
    norm = np.sqrt(np.maximum(window_energy, 1.) * np.dot(target, target))
    spectrum = np.fft.rfft(audio, count)
    def score(reference):
        values = np.fft.irfft(spectrum * np.fft.rfft(reference[::-1], count), count)
        return float(np.max(np.abs(values[len(target)-1:len(audio)]) / norm))
    # Reversed voiced speech can retain periodic vowel structure. A seeded
    # phase-randomized control preserves the spectrum but destroys timing.
    spectrum_target = np.fft.rfft(target)
    phase = np.exp(2j * np.pi * np.random.default_rng(660).random(len(spectrum_target)))
    control = np.fft.irfft(np.abs(spectrum_target) * phase, n=len(target))
    control -= control.mean()
    control *= np.sqrt(np.dot(target, target) / max(np.dot(control, control), 1.))
    # Lossy codecs and asynchronous device clocks can decorrelate a long
    # waveform. Require three independently matched short segments in order,
    # with consistent delay, instead of weakening the whole-phrase threshold.
    segments = []
    length = min(4000, len(target)//6)
    for fraction in (.10, .35, .60, .85):
        offset = int(fraction * (len(target)-length))
        segment = target[offset:offset+length].copy()
        segment -= segment.mean()
        power = np.dot(segment, segment)
        if power < 1:
            continue
        values = np.fft.irfft(spectrum * np.fft.rfft(segment[::-1], count), count)
        energies = energy[length:] - energy[:-length]
        scores = np.abs(values[length-1:len(audio)]) / np.sqrt(np.maximum(energies, 1.) * power)
        position = int(np.argmax(scores))
        segments.append({'correlation': float(scores[position]),
                         'relativeOffsetSeconds': (position-offset)/8000})
    strong = [v for v in segments if v['correlation'] >= .35]
    ordered = any(max(v['relativeOffsetSeconds'] for v in subset) -
                  min(v['relativeOffsetSeconds'] for v in subset) <= .35
                  for subset in itertools.combinations(strong, 3))
    return {'correlation': score(target), 'reversedControlCorrelation': score(target[::-1]),
            'phaseControlCorrelation': score(control), 'segments': segments,
            'orderedSpeechSegments': ordered}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sender', required=True, help='AVD console port, e.g. 5558')
    parser.add_argument('--receivers', nargs='+', required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--proto-dir', type=Path, default=Path('.build/macos/emulator-audio-proto'))
    parser.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
    args = parser.parse_args()
    serials = [args.sender, *args.receivers]
    if len(set(serials)) != len(serials) or not all(re.fullmatch(r'\d+', s) for s in serials):
        parser.error('Use distinct numeric emulator console ports')
    os.umask(0o077)
    sys.path.insert(0, str(args.proto_dir.resolve()))
    import emulator_controller_pb2 as pb
    import emulator_controller_pb2_grpc as rpc
    with wave.open(str(args.source), 'rb') as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (48000, 1, 2):
            parser.error('Source must be 48 kHz, mono, signed 16-bit WAV')
        source = audio.readframes(audio.getnframes())
    duration = len(source) / 96000
    if not 1 <= duration <= 15:
        parser.error('Synthetic source duration must be 1–15 seconds')
    template = np.frombuffer(source, dtype='<i2')

    def adb(serial, *values):
        return subprocess.check_output([args.adb, '-s', 'emulator-' + serial, *values],
                                       text=True, timeout=30).strip()

    def ui(serial):
        adb(serial, 'shell', 'rm', '-f', '/sdcard/koeon-audio-probe.xml')
        confirmation = adb(serial, 'shell', 'uiautomator', 'dump', '/sdcard/koeon-audio-probe.xml')
        if 'dumped to:' not in confirmation:
            raise RuntimeError('Fresh UI dump not confirmed')
        return ET.fromstring(adb(serial, 'exec-out', 'cat', '/sdcard/koeon-audio-probe.xml'))

    def center(node):
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
        return str((x1+x2)//2), str((y1+y2)//2)

    # Complete subprocess setup before creating gRPC worker threads.
    for serial in serials:
        if adb(serial, 'shell', 'getprop', 'ro.kernel.qemu') != '1':
            raise RuntimeError('Only Android emulators are supported')
        adb(serial, 'shell', 'am', 'start', '-n', 'com.dennomuso.koeon/.MainActivity')
        root = ui(serial)
        on = [n for n in root.iter('node') if n.get('text') == 'POWER ON · START']
        if on:
            adb(serial, 'shell', 'input', 'tap', *center(on[0]))
            time.sleep(4)
            root = ui(serial)
        ready = [n for n in root.iter('node') if n.get('content-desc') == 'Push to talk, READY']
        if len(ready) != 1:
            raise RuntimeError('Every selected AVD must be enrolled, foreground and READY')
        if serial == args.sender:
            coordinates = center(ready[0])
            x1, y1, x2, y2 = map(int, re.findall(r'\d+', ready[0].get('bounds')))
            if y2-y1 < 300 or x2-x1 < 300 or int(coordinates[1]) < 160:
                raise RuntimeError('PTT button is clipped; scroll it fully into view before testing')

    discovery = Path.home() / 'Library/Caches/TemporaryItems/avd/running'
    endpoints = {}
    for file in discovery.glob('pid*.ini'):
        values = dict(line.split('=', 1) for line in file.read_text().splitlines() if '=' in line)
        serial = values.get('port.serial')
        if serial in serials and values.get('grpc.token'):
            channel = grpc.insecure_channel('127.0.0.1:' + values['grpc.port'])
            endpoints[serial] = (rpc.EmulatorControllerStub(channel),
                                 [('authorization', 'Bearer ' + values['grpc.token'])], channel)
    if set(endpoints) != set(serials):
        raise RuntimeError('Missing authenticated localhost gRPC endpoint')
    microphone_states = {}
    press = None
    result = {'sender': args.sender, 'sourceSeconds': duration, 'rawReceiverAudioSaved': False,
              'injectionCompleted': False, 'pressCoordinates': coordinates}
    fmt = pb.AudioFormat(samplingRate=48000, channels=pb.AudioFormat.Mono,
                         format=pb.AudioFormat.AUD_FMT_S16, mode=pb.AudioFormat.MODE_REAL_TIME)
    hold = duration + 20  # UI dumps can stall on a busy multi-AVD host.

    def capture(serial):
        stub, metadata, _ = endpoints[serial]
        samples = []
        formats = set()
        end = None
        try:
            for packet in stub.streamAudio(fmt, metadata=metadata, timeout=hold+5):
                formats.add((packet.format.samplingRate, packet.format.channels, packet.format.format))
                count = len(packet.audio)//2
                samples.extend(struct.unpack('<' + 'h'*count, packet.audio[:count*2]))
        except grpc.RpcError as error:
            end = error.code().name
        output = {'sampleCount': len(samples), 'captureEnd': end,
                  'formats': sorted(formats), **correlation(samples, template)}
        output['knownSpeechDetected'] = (end == 'DEADLINE_EXCEEDED' and
            formats == {(48000, 0, 1)} and output['correlation'] >= .10 and
            output['orderedSpeechSegments'])
        return output

    captures = {}
    try:
        for serial, (stub, metadata, _) in endpoints.items():
            microphone_states[serial] = stub.getMicrophoneState(Empty(), metadata=metadata, timeout=5).realAudioEnabled
            stub.setMicrophoneState(pb.MicrophoneState(realAudioEnabled=False), metadata=metadata, timeout=5)
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(args.receivers)) as executor:
            captures = {s: executor.submit(capture, s) for s in args.receivers}
            time.sleep(1)
            press_started = time.monotonic()
            press = subprocess.Popen([args.adb, '-s', 'emulator-'+args.sender, 'shell', 'input',
                                      'swipe', *coordinates, *coordinates, str(int(hold*1000))])
            time.sleep(1)
            talking = any(n.get('content-desc') == 'Push to talk, TALKING' for n in ui(args.sender).iter('node'))
            result['talkingObservedBeforeInjection'] = talking
            if not talking:
                raise RuntimeError('Actual sender TALKING state not observed; no audio injected')
            remaining = hold - (time.monotonic() - press_started)
            result['gestureBudgetBeforeInjectionSeconds'] = remaining
            result['gestureActiveBeforeInjection'] = press.poll() is None
            if press.poll() is not None or remaining < duration + 1:
                raise RuntimeError('PTT gesture window expired or too short; no audio injected')
            injection_started = time.monotonic()
            result['injectionStartedAfterGestureSeconds'] = injection_started - press_started
            def packets():
                start = time.monotonic()
                for frame in range(math.ceil(duration/.02)):
                    yield pb.AudioPacket(format=fmt, timestamp=int(time.time()*1e6),
                                         audio=source[frame*1920:(frame+1)*1920])
                    time.sleep(max(0., start + (frame+1)*.02 - time.monotonic()))
            stub, metadata, _ = endpoints[args.sender]
            stub.injectAudio(packets(), metadata=metadata, timeout=duration+8)
            result['injectionCompleted'] = True
            result['injectionDurationSeconds'] = time.monotonic() - injection_started
            result['gestureActiveAfterInjection'] = press.poll() is None
            if press.poll() is not None:
                raise RuntimeError('PTT gesture ended before injection completed; invalid audio trial')
            press.wait(timeout=hold+5)
            result['receivers'] = {s: f.result(timeout=hold+10) for s, f in captures.items()}
    except Exception as error:
        result['probeError'] = type(error).__name__
        if isinstance(error, grpc.RpcError):
            result['probeTransportErrorCode'] = error.code().name
        if isinstance(error, RuntimeError):
            result['probeErrorDetail'] = str(error)
        result['receivers'] = {s: f.result() for s, f in captures.items() if f.done() and f.exception() is None}
    finally:
        # The gesture is finite even if the client failed; do not kill it while DOWN.
        result['cleanupErrors'] = []
        if press is not None and press.poll() is None:
            try:
                press.wait(timeout=hold+5)
            except subprocess.TimeoutExpired:
                result['cleanupErrors'].append('finite_gesture_wait_timeout')
        for serial, (stub, metadata, channel) in endpoints.items():
            try:
                if serial in microphone_states:
                    stub.setMicrophoneState(pb.MicrophoneState(realAudioEnabled=microphone_states[serial]), metadata=metadata, timeout=5)
            except Exception as error:
                result['cleanupErrors'].append('microphone_restore_' + serial + '_' + type(error).__name__)
            finally:
                channel.close()
    try:
        result['senderReadyAfter'] = any(n.get('content-desc') == 'Push to talk, READY'
                                         for n in ui(args.sender).iter('node'))
    except Exception as error:
        result['senderReadyAfter'] = False
        result['senderInspectionError'] = type(error).__name__
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    return 0 if result['injectionCompleted'] and 'probeError' not in result and not result.get('cleanupErrors') and result['senderReadyAfter'] and set(result.get('receivers', {})) == set(args.receivers) and all(v['knownSpeechDetected'] for v in result['receivers'].values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
