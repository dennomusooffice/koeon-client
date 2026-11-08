#!/usr/bin/env python3
import argparse, plistlib
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('source', type=Path)
p.add_argument('--role', default='ios27', choices=['ios27'])
a = p.parse_args()
config = plistlib.loads(a.source.read_bytes())
target = config['KOEONTests']
target.setdefault('EnvironmentVariables', {})['KOEON_MIXED_LAB_ROLE'] = a.role
target['OnlyTestIdentifiers'] = ['MixedEmulatorTransportTests']
output = a.source.with_name('KOEON_mixed_lab.xctestrun')
output.write_bytes(plistlib.dumps(config))
print(output)
