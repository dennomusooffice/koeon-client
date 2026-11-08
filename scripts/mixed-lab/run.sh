#!/bin/bash
# Run from repository root after building both test bundles and booting lab AVDs.
set -euo pipefail
: "${LAB_IOS_UDID:?Specify a Simulator UDID, never a physical device}"
: "${LAB_XCTESTRUN:?Specify the prepared mixed lab xctestrun file}"
results=.build/macos/mixed-lab
mkdir -p "$results"
# Do not take over a port owned by another process.
if curl -fsS --max-time 1 http://127.0.0.1:18765/lab/status >/dev/null 2>&1; then
  echo 'Port 18765 already serves a lab. Stop the prior owned run first.' >&2; exit 2
fi
xcrun simctl list devices available -j | python3 -c 'import json,os,sys; d=json.load(sys.stdin); assert any(x["udid"]==os.environ["LAB_IOS_UDID"] for xs in d["devices"].values() for x in xs), "Simulator ID not found"'
# Complete installation before starting the bounded peer wait in XCTest.
if [[ "${LAB_PREPARED:-0}" != 1 ]]; then
  scripts/mixed-lab/android-test.sh emulator-5554 android35 prepare > "$results/prepare35.log" 2>&1
  scripts/mixed-lab/android-test.sh emulator-5556 android36 prepare > "$results/prepare36.log" 2>&1
fi
python3 scripts/mixed-lab/server.py > "$results/server.log" 2>&1 &
lab_server_pid=$!
trap 'kill "$lab_server_pid" 2>/dev/null || true; wait "$lab_server_pid" 2>/dev/null || true' EXIT
for ((attempt=0; attempt<30; attempt++)); do
  if curl -fsS http://127.0.0.1:18765/lab/status >/dev/null 2>&1; then break; fi
  sleep 1
done
scripts/mixed-lab/android-test.sh emulator-5554 android35 run > "$results/android35.log" 2>&1 &
lab_android35_pid=$!
scripts/mixed-lab/android-test.sh emulator-5556 android36 run > "$results/android36.log" 2>&1 &
lab_android36_pid=$!
xcodebuild test-without-building -xctestrun "$LAB_XCTESTRUN" \
  -destination "platform=iOS Simulator,arch=arm64,id=$LAB_IOS_UDID" \
  -parallel-testing-enabled NO -collect-test-diagnostics never > "$results/ios.log" 2>&1 &
lab_ios_pid=$!
failed=0
wait "$lab_android35_pid" || failed=1
wait "$lab_android36_pid" || failed=1
wait "$lab_ios_pid" || failed=1
curl -fsS http://127.0.0.1:18765/lab/status > "$results/results.json"
python3 - "$results/results.json" <<'PY'
import collections,json,sys
x=json.load(open(sys.argv[1])); counts=collections.Counter(r['role'] for r in x['results'])
assert counts=={'android35':12,'android36':12,'ios27':12},counts
roles=['android35','android36','ios27']
scenarios=['normal','transient','expired','recovered']
assert {(r['role'],r['sender'],r['scenario']) for r in x['results']} == {(r,s,c) for r in roles for s in roles for c in scenarios}
for role in roles:
    for sender in roles:
        assert x['attempts'][role+':'+sender+'-transient'] >= 7
for role in roles[:2]:
    assert x['attempts'][role+':lab-stalled'] >= 1
for r in x['results']:
    expected = (0 if r['role']=='ios27' else 4) if r['scenario']=='expired' else 32
    assert r['frames']==expected,r
print('36 native transport cases verified; expired-head behavior differs by OS')
PY
exit "$failed"
