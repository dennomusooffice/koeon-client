# Mixed native transport lab

Current LiveKit / RTP tooling: [RTP_LAB.md](RTP_LAB.md).
The standard simulator and physical-device matrices are documented in [docs/testing](../../docs/testing).

The BATv1 HTTP/PCM fixture, runners and native fixture tests were removed under
[Issue #66](https://github.com/dennomusooffice/koeon-client/issues/66).
Historical 36-case results remain in Git history (baseline `3951216`). They are
not validation of the current LiveKit-only client, background audio, or Bluetooth.
HTTP request cancellation coverage remains in native API tests against Floor status.

Retained tools cover RTP shaping, emulator bandwidth/recovery and acoustic probes.
See [EMULATOR_AUDIO.md](EMULATOR_AUDIO.md) for known simulator audio limitations.
