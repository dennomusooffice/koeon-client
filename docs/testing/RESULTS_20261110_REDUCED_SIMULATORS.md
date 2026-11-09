# Reduced simulator investigation — 2026-11-10 JST

Related: [#56](https://github.com/dennomusooffice/koeon-client/issues/56), [#57](https://github.com/dennomusooffice/koeon-client/issues/57), [#58](https://github.com/dennomusooffice/koeon-client/issues/58), [PR #76](https://github.com/dennomusooffice/koeon-client/pull/76).

## Candidates and scope

Android 1.0.19 (20), source `b35d6d59923fbfdc7b1242ab25304ce7b3bd10bb`, signed APK SHA256 `d47fceec065aeb1b8b2a5b66e1c9c01e5f2827927504c1cde0b7813127ecc704`. Physical iPhone remains 1.0 (2026111002), source `ecb19a4527ddfcd2d42571b1acf82f397982441c`. No physical microphone/vehicle acceptance in this session. Real clients were not powered off; selected AVD count is not total LiveKit room membership.

Mac 32 GiB, Emulator 37.2.13.0; start with all simulators off, then Android 15, then Android 14+15, then Android 14+15+16. API37 and iOS Simulator stay off. No builds run concurrently with synthetic speech trials. Existing enrollments retained. No carrier/Wi-Fi changes on physical OPPO.

## Findings

- CarPlay fails even with zero simulators: DeviceHub Connecting → Disconnected, CoreDeviceError 4000 / POSIX 83 (EDEVERR), remote-iap service socket creation failure. iPhone unlocked; developer-device info works. Quitting/relaunching DeviceHub repeats failure. Thus concurrent AVD memory load is not necessary to reproduce this connection problem. Tool/iOS service compatibility remains a hypothesis. Additional Tools CarPlay comparison blocked by Apple Account sign-in; no credentials requested overnight. No entitlement/OS changes made.
- API37 emulator silently raises requested 1536 MiB to its required 4096 MiB. Lab tooling now budgets this explicitly and supports a persisted `--only` subset, with six unit tests. This is a test-environment correction, not proof of an application OOM.
- Two-AVD control: six trials pass, three rounds in each direction. Synthetic speech Android14→15: three consecutive passes (~1.53M samples per receiver); after 15-second network outage, another pass. Known-speech correlation and ordered segments, not human intelligibility.
- Android15 network loss during held PTT: OFFLINE, then READY after restoration while the gesture remains held; no automatic TX restart. New PTT after idle outage works.
- Emulator-configured 128000 bps up/down, 150–250ms delay on Android15: Android14→15 and 15→14 both detect the synthetic speech. Rate setting verified; this is not measured carrier throughput or full loss/jitter acceptance. Restored unlimited speed/zero delay.
- Three-AVD speech Android14→15+16: first two rounds pass both receivers; third fails both with ~1.53M captured samples but zero known-speech correlation. Sender journal: TRANSMITTING 06:16:30.822 → RECONNECTING/RELEASING 06:16:36.183 → IDLE 06:16:36.337 → CONNECTED 06:16:37.174. RX_READY 0/5. Android15 last START belongs to the preceding round; it separately reconnects 06:16:41.591–42.466. Safety cancellation is appropriate; underlying reconnect trigger is unresolved.
- At the failed trial, memory_pressure reports 70% free; swap usage stays 4909.75 MiB and swapouts do not increase. Historical swap allocation is not contemporaneous OOM evidence. This does not rule out memory involvement in previous eight-device failures.
- Receiver HAL output-write errors remain zero. Android15 input-read errors also appear in successful tests; they are not by themselves proof of the missing received audio. Mac default audio input/output is built-in, not iPhone Continuity audio.

## Follow-up and limits

A separate Android diagnostic branch adds strict fixed-category SDK transport logging to distinguish publisher/subscriber disconnect, signal/ping and network-change recovery. No reconnect behavior is weakened; no automatic microphone restart is added. Server Docker logs are unavailable to the current SSH deploy account. Failure must be correlated with transport events/server logs before declaring a root-cause fix. API37, iOS, physical Bluetooth and vehicle audio are not covered by the reduced audio result. Raw logs, identities and audio are not published.

Final candidate, cleanup and follow-up evidence are recorded on #57 and related PRs. This report does not close the unresolved issues or claim general stability.

Follow-up #77 records internal diagnostics 1.0.20 (21) and 1.0.21 (22), server CONNECTION_TIMEOUT/STATE_MISMATCH evidence, and a separate Android16 input-HAL/known-speech test limitation. The synthetic probe now explicitly labels injection acknowledgment as emulator-gRPC-only and sender microphone verification as unknown. This prevents interpreting successful injection RPC as proof of a valid input waveform. See its README acceptance boundary; failed trials remain failed/inconclusive, never silently promoted to passes.
