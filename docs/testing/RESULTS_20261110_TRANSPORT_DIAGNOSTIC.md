# Transport failure investigation, 2026-11-10 JST

Follow-up to [reduced simulator report](https://github.com/dennomusooffice/koeon-client/pull/76) and [Issue #57](https://github.com/dennomusooffice/koeon-client/issues/57). Raw device/server identifiers and logs stay private.

## Evidence and changes

Android 1.0.19 (20), b35d6d59923fbfdc7b1242ab25304ce7b3bd10bb: three AVDs reproduced a sender reconnect during TX after two successful rounds. See #57 for 06:16 timeline. Memory counters and receiver output-write errors do not support treating this particular failure as the earlier heavy-build/OOM case.

Diagnostic 1.0.20 (21), b47eea4bdf94ad46597203ba765e102233d9af43, APK SHA256 `4ac2df1b3f667a6fe4429f175bdaf59c7ff66d0f9276183e505892025d74cc61`: first Android14→15+16 speech round passed both; second failed both. Sender events:

| Time JST | Category |
| --- | --- |
| 06:29:03.686 | ICE_UNSCOPED_DISCONNECTED |
| 06:29:06.265 | PUBLISHER_DISCONNECTED |
| 06:29:07.646 | SIGNAL_CLOSED, followed by reconnect attempts |
| 06:29:08.948 | PUBLISHER_CONNECTED |
| 06:29:09.904 | SUBSCRIBER_CONNECTED |

Neither receiver records a simultaneous disconnect. This locates the observed interruption in the sender transport, not merely its receiver speaker route. It does not identify which network hop or SDK/server behavior broke ICE. The later signal close must not be assumed to be the initiating cause.

A/B comparison changed only sender AVD launch to `-feature -WiFiPacketStream`, an [official legacy networking option](https://developer.android.com/studio/run/emulator-networking-interconnect). Same app/candidate, same two receivers: first round passed, second failed. Sender publisher disconnect 06:31:56.866 precedes signal close 06:32:00.729. Thus the new shared emulator networking alone does not explain the issue. The option is per launch, not a persisted AVD configuration change.

Wi-Fi status reports three distinct MACs and IPs; no duplicate was observed. Host airportd search matched saved-network/autojoin summaries rather than an actual disconnect at the failure time. Sampled host CPU was 74–77% idle. These are bounded observations, not proof that all external network/CPU issues are impossible.

Diagnostic 1.0.21 (22), source `3b916970d6c3dd1ea2c1a2f762186bbb58822bc3`, APK SHA256 `f7596ed716e1f57b8172151e38ce924cc873b6c690645bb43d8605be5e8639aa`, additionally records an allowlisted server LEAVE category and numeric close code. Both diagnostic versions passed 205 Android unit tests and exact-source/signature/parity candidate checks. The only app change is diagnosis; safe TX cancellation is unchanged. Installed on the three AVDs only; no public release, physical-device update or merge.

## Continuing investigation

- Inspect exported 24-hour `TRANSPORT` journal events before the first RECONNECTING event. Preserve relative ordering across TX, RX_READY and server Floor records. ICE_UNSCOPED does not identify which peer connection; PUBLISHER and SUBSCRIBER do.
- Correlate the next failure with server-side LiveKit transport/leave logs for the same UTC interval. The configured SSH deploy account cannot access Docker or the LiveKit service journal; no permission or production changes were made.
- Do not weaken safe TX stop or resume a held microphone automatically. Do not label a later passing run a functional fix when only logging changed.
- Physical Bluetooth, iOS background audio and actual CarPlay acoustics are not validated by this AVD test. CarPlay DeviceHub connection separately fails at remote-iap service socket creation with all simulators off; see #58. Additional Tools comparison requires Apple developer sign-in or an available vehicle environment.

Final repetitions, cleanup and unresolved status are appended to PR #77 / Issue #57. No issue is automatically closed.

Build22 Android14→15+16: six consecutive synthetic-speech trials passed both receivers. Sender still uses the legacy per-launch network flag; no server LEAVE reproduced during these trials. This is an intermittent-failure observation, not proof that the diagnostic code fixed transport.

Build22 rotated sender: Android15→14+16 passed twice. Android16→14+15 did not detect speech at either receiver, but sender diagnostic input was entirely silent (-120 dBFS RMS/peak, 421,920 meter samples) and its HAL logged repeated late-input silence insertion / read I/O failures. gRPC injection acknowledgment alone does not prove microphone capture. Treat this trial as inconclusive for app transport, not proof that both receivers failed due to the same defect; do not weaken the speech detector to pass silence.

Independently, Android14 records SERVER_LEAVE_CONNECTION_TIMEOUT at 06:43:14.858, before local ICE disconnect at 06:43:19.861 and publisher disconnect at 06:43:21.932; SIGNAL_CLOSED_3500 at 06:43:25.645, then SERVER_LEAVE_STATE_MISMATCH at 06:43:25.870 during resume. It fully reconnects by 06:43:27.730. This establishes a server-directed session timeout in this occurrence, not its upstream cause or the cause of silence at both receivers. The [protocol definitions](https://github.com/livekit/protocol/blob/main/protobufs/livekit_models.proto) distinguish session timeout from a resume unknown to the server. Export verified 66 persisted TRANSPORT records for build22 on Android14, with only the allowlisted reason field.

Android16-only cold reboot with identical app/settings: one repeat still failed ordered-speech detection at both receivers (correlation ~0.09). Sender meter became nonzero (421,760 samples, RMS -35.58 dBFS, peak -2.43 dBFS), but this does not verify capture of the complete known waveform. Android15 recorded the START at 06:47:55.971 and successfully published RX_READY at 06:47:55.976. Keep input fidelity versus media delivery unresolved; do not count this as a successful audio test or claim that a missing START explains it. Reboot alone did not resolve the signal-detection failure. Diagnostic snapshots and post-trial logcats were preserved before shutdown.
