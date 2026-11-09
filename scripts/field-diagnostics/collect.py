#!/usr/bin/env python3
"""Import exported journals, preserve checksums, and correlate without publishing private data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import time

SCHEMA = 'koeon.field-journal.v1'
MAX_INPUT = 64 * 1024 * 1024
HASH = re.compile(r'^[0-9a-f]{64}$')
ENUM = re.compile(r'^[A-Z][A-Z0-9_]{0,63}$')
LABEL = re.compile(r'^[a-zA-Z0-9_-]{1,48}$')
KEYS = set('connection ptt rx operational lifecycle audio route mode runtimeGeneration receiveGeneration firstPcm pcmCallbacks pcmFrames pcmAtMs rxStartedAtMs txDownAtMs gainDb gainSamples gainDecision recoveryLevel restoring trackSubscribed participants readyExpected readyReceived readyTimedOut clockDiscontinuity'.split())
CORRELATIONS = ('sessionHash', 'speakerSessionHash', 'leaseHash', 'channelHash')

def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()

def safe_data(value):
    if not isinstance(value, dict):
        return {}
    return {k: v for k, v in value.items() if k in KEYS and
            (isinstance(v, bool) or type(v) in (int, float) and abs(v) < 1e18 or
             isinstance(v, str) and ENUM.fullmatch(v))}

def load_bundle(path):
    path = Path(path)
    if path.stat().st_size > MAX_INPUT:
        raise ValueError('input exceeds 64 MiB')
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or value.get('schema') != 'koeon.field-journal-export.v1' or not isinstance(value.get('records'), list):
        raise ValueError('expected exported journal bundle')
    if not isinstance(value.get('manifest'), dict):
        raise ValueError('missing manifest')
    return value

def normalize(record, label, offset=0, server=False):
    if not isinstance(record, dict) or type(record.get('wallTimeMs')) is not int:
        raise ValueError('missing integer wallTimeMs')
    if not server and record.get('schema') != SCHEMA:
        raise ValueError('unsupported record schema')
    event = record.get('event')
    if not isinstance(event, str) or not ENUM.fullmatch(event):
        raise ValueError('event must be fixed uppercase classification')
    correlation = record.get('correlation', {})
    if not isinstance(correlation, dict):
        raise ValueError('invalid correlation')
    correlation = {k: v for k, v in correlation.items() if k in CORRELATIONS and isinstance(v, str) and HASH.fullmatch(v)}
    if server:
        for key in CORRELATIONS:
            raw_key = key.replace('Hash', 'Id')
            raw = record.get(raw_key)
            if isinstance(raw, str) and raw:
                correlation[key] = digest(raw)
    out = dict(source=label, event=event, wallTimeMs=record['wallTimeMs'],
               adjustedTimeMs=record['wallTimeMs'] + offset, clockOffsetMs=offset,
               correlation=correlation, data=safe_data(record.get('data')))
    for key in ('sequence', 'monotonicMs', 'droppedBefore', 'ioFailuresBefore'):
        if type(record.get(key)) is int:
            out[key] = record[key]
    # UUID-only identity; never forward arbitrary labels/credentials from malformed input.
    for key in ('runId', 'installationId'):
        value = record.get(key)
        if isinstance(value, str) and re.fullmatch(r'[0-9a-fA-F-]{36}', value):
            out[key] = value
    out['clockDiscontinuity'] = record.get('clockDiscontinuity') is True
    return out

def correlate(devices, servers=(), offsets=None):
    offsets = offsets or {}
    records, inputs, rejected, duplicate = [], [], 0, 0
    seen = set()
    for label, bundle in devices:
        inputs.append({'source': label, 'manifest': {k: v for k, v in bundle['manifest'].items()
            if k in ('exportedAtMs', 'cutoffMs', 'recordCount', 'capacityDroppedRecordsLifetime',
                     'corruptDroppedRecordsLifetime', 'futureClockRecordsExcluded', 'ioFailuresThisRun', 'retentionMs', 'maxBytes') and type(v) is int}})
        for raw in bundle['records']:
            try:
                row = normalize(raw, label, offsets.get(label, 0))
            except (ValueError, TypeError):
                rejected += 1; continue
            key = (row.get('installationId'), row.get('runId'), row.get('sequence'))
            # Same export under another alias still deduplicates. Missing identity falls back to full row.
            key = key if all(v is not None for v in key) else json.dumps(row, sort_keys=True)
            if key in seen:
                duplicate += 1; continue
            seen.add(key); records.append(row)
    for label, raw in servers:
        try:
            records.append(normalize(raw, label, offsets.get(label, 0), server=True))
        except (ValueError, TypeError):
            rejected += 1
    records.sort(key=lambda r: (r['adjustedTimeMs'], r['source'], r.get('sequence', 0)))
    leases, uncorrelated = {}, 0
    for row in records:
        lease = row['correlation'].get('leaseHash')
        if not lease:
            uncorrelated += 1; continue
        group = leases.setdefault(lease, {'sources': set(), 'events': set(), 'recordCount': 0})
        group['sources'].add(row['source']); group['events'].add(row['event']); group['recordCount'] += 1
    groups = []
    for lease, value in leases.items():
        groups.append(dict(leaseHash=lease, sources=sorted(value['sources']), events=sorted(value['events']),
            recordCount=value['recordCount'], missingEvidence=[] if 'RX_PCM' in value['events'] else ['validated RX_PCM not recorded'],
            audibility='NOT_MEASURED'))
    # Sequence gaps are only meaningful within one source/run. They are evidence gaps, not packet loss.
    runs = {}
    for row in records:
        if 'runId' in row and 'sequence' in row:
            runs.setdefault((row['source'], row['runId']), set()).add(row['sequence'])
    gaps = sum(max(seq) - min(seq) + 1 - len(seq) for seq in runs.values() if seq)
    return dict(schema='koeon.field-correlation.v1', inputs=inputs, rejectedRecords=rejected,
        duplicateRecords=duplicate, sequenceGapsWithinExports=gaps, uncorrelatedRecords=uncorrelated,
        leases=groups, records=records,
        limitations=['PCM metadata does not prove audibility.', 'Cross-device monotonic timestamps are not comparable.',
                     'No lease hash means no inferred transmission match.', 'Offsets are operator measurements; wall clocks may drift.'])

def assignment(value):
    label, sep, path = value.partition('=')
    if not sep or not LABEL.fullmatch(label) or not path:
        raise argparse.ArgumentTypeError('expected safe-label=value')
    return label, path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', action='append', type=assignment, default=[], help='label=export.json (repeatable)')
    parser.add_argument('--server', action='append', type=assignment, default=[], help='label=adapter.jsonl; raw input is NOT copied')
    parser.add_argument('--offset', action='append', type=assignment, default=[], help='label=milliseconds added to source wall clock')
    parser.add_argument('--output', required=True, type=Path, help='new private directory, preferably .secret/field-runs/<run>')
    args = parser.parse_args()
    if not args.device:
        parser.error('at least one --device required')
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    devices, servers, manifest = [], [], []
    labels = [label for label, _ in args.device + args.server]
    if len(labels) != len(set(labels)):
        parser.error('source labels must be unique')
    for label, path in args.device:
        bundle = load_bundle(path); devices.append((label, bundle))
        destination = args.output / (label + '.json')
        shutil.copyfile(path, destination); destination.chmod(0o600)
        manifest.append(dict(source=label, file=destination.name, sha256=hashlib.sha256(destination.read_bytes()).hexdigest()))
    for label, path in args.server:
        path = Path(path)
        if path.stat().st_size > MAX_INPUT:
            raise ValueError('server input exceeds 64 MiB; select relevant interval')
        with path.open() as stream:
            for line in stream:
                if len(line) > 256 * 1024:
                    raise ValueError('server adapter line too large')
                try: raw = json.loads(line)
                except json.JSONDecodeError: raw = None
                servers.append((label, raw))
    report = correlate(devices, servers, {k: int(v) for k, v in args.offset})
    (args.output / 'correlation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    (args.output / 'manifest.json').write_text(json.dumps(dict(createdAtMs=int(time.time()*1000), inputs=manifest), indent=2) + '\n')
    print(json.dumps(dict(devices=len(devices), records=len(report['records']), leases=len(report['leases']),
                         rejected=report['rejectedRecords'], output=str(args.output))))

if __name__ == '__main__':
    main()
