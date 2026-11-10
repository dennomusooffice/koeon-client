# Physical PTT input: Xiaomi investigation (#79)

This is an opt-in test transport, not an application change or a general device
compatibility guarantee. Never use a successful ADB exit as a transmission result.
The app must accept DOWN, acquire Floor, enter TALKING, release and return READY;
receiving peers must be observed separately. Audio audibility remains a separate
acceptance gate.

## Scope and dependencies

Use only the explicitly authorized device and current test window. Keep device
registration, security settings and Floor authority intact. Do not install an
accessibility bypass, disable verification or persist microphone audio.

`scrcpy_ptt.py` uses the official scrcpy **5.0.1** server in control-only mode:

- Source/protocol: https://github.com/Genymobile/scrcpy/tree/v5.0.1
- Server: https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1
- SHA-256: `764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`

Obtain the pinned server separately. The JAR is not committed. Verification occurs
before device access. Video, audio and clipboard auto-sync are disabled. Only the
owned random remote JAR and ADB forward are removed on exit. The supplied log
stream and device identifiers belong in a private, access-controlled run folder.
Normal Android shell input permissions are required; an OS denial is a blocker.

## Procedure

1. Record original screen/sleep settings and set a bounded testing deadline. Verify
   the device is unlocked and KOEON is READY. Do not change its registration.
2. Read the current screen dimensions and PTT bounds before the hold. Verify a
   non-action area visually if using the initialization workaround below.
3. Open one `ScrcpyTouch(adb, serial, server, width, height, expires_at, log)` context.
4. For the affected Xiaomi, optionally call `initialize_at(x, y)` **only on a verified
   non-action area**, never on PTT or a settings control. Retain the connection.
5. Call `hold(x, y, seconds, observe)` for 1–10 seconds. The observer must be bounded
   and passive (screenshots and peer evidence); avoid UIAutomator on the held device.
   A timer schedules UP independently of observation; finally sends UP again.
6. Check the returned evidence and post-release state, plus diagnostic DOWN/UP/CANCEL
   counters. `OBSERVATION_REQUIRED` is deliberately not PASS. Never auto-retry a
   failed transmission as if it were the same test.
7. Close the context, verify release, restore original settings and stop owned
   emulators by the authorized deadline. A failed cleanup must stop further trials.

The Python timer cannot guarantee release after host power loss or process kill.
The application’s own transmission bounds remain required. The older
`physical_ptt.py` DOWN/sleep/UP helper is an experimental fallback: it was unreliable
on this Xiaomi and must not be selected as a verified solution.

## Evidence and limits

Issue: https://github.com/dennomusooffice/koeon-client/issues/79

On Android 16 Xiaomi / public KOEON 1.0.19(20), ordinary `input swipe` could exit 0
without an accepted app DOWN. OS logs included input-injection failures. A persistent
scrcpy connection without initialization also lost its first PTT in repeated
3-gesture comparisons (2/3 TALKING), including a comparison without UIAutomator.
A verified non-action DOWN/UP before PTT produced 3/3 TALKING, with matched app
DOWN/UP counters and no CANCEL. This establishes a candidate workaround, **not**
a proven internal MIUI root cause. Further run results belong in #79; do not infer
Bluetooth sound, latency, or general stability from the input test.

Tests: `python3 -m unittest discover -s scripts/test-lab/tests -p '*ptt.py'`.
They cover deadline/coordinate/duration rejection, release after an observer
exception, cleanup release, and checksum rejection before device access. They do
not substitute for device validation.

2026-11-10 follow-up: the checked-in control transport, initialized once in a
verified non-action area, completed **5/5** eight-second PTT trials. Each trial
observed Xiaomi TALKING then READY and all five peers BUSY_REMOTE then READY.
App counters advanced from 16/16/0 to 21/21/0 (DOWN/UP/CANCEL). Peers were Android
14–17 plus iOS simulator, with mixed build versions recorded privately and in #79.
This verifies bounded control behavior for that run, not acoustic acceptance.
Android 16/17 required QEMU restart and ordinary POWER ON before the final run.
