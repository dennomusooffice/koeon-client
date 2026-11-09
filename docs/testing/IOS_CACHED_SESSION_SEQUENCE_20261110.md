# iOS cached-session reconnect control sequence

Tracked by [Issue #74](https://github.com/dennomusooffice/koeon-client/issues/74).

The 1.0 (2026111001) candidate at b35d6d59923fbfdc7b1242ab25304ce7b3bd10bb resets the outbound control sequence on LiveKit transport disconnect. FAST_COLD_RECONNECT can reuse the backend session while connected receivers retain that session's replay watermark. A subsequent START can therefore be rejected as stale.

Keep the sequence for the lifetime of LiveKitRoomController, including transport disconnects. Both ordinary control publication and START use one allocator. Receiver replay checks, server floor authorization, media routing and wire fields are unchanged.

## Verification, 2026-11-10 JST

- Before removing the reset, a real controller disconnect test failed both monotonicity assertions. A receiver integration test using the same session and a new lease failed three assertions: the lease was rejected, the receive generation did not advance, and staleIgnored became 1.
- After the fix, the full iOS suite on the separate iOS 27.2 arm64 simulator executed 257 tests: 256 passed, one SFU-specific test skipped, zero failures. Completed 04:43 JST.
- The initial test command omitted the arm64 restriction and failed to resolve LiveKit for x86_64; it is an environment failure, not the regression's failing-test evidence.
- No real-device cached-session reconnect acceptance is claimed. The mixed-device missing BUSY/audio observations have not been attributed to this defect. CarPlay projection connection failure and Android floor-lease failures remain separate investigations.
- This record describes implementation and automated verification only. Distribution, device validation and merge status must be recorded separately on the Issue/PR.

Reproduction uses the existing KOEONTests scheme with CODE_SIGNING_ALLOWED=NO, ARCHS=arm64 and ONLY_ACTIVE_ARCH=YES. The two targeted cases are PTTControllerTests.testControlSequenceSurvivesCachedSessionDisconnect and RxAudioControllerTests.testConnectedReceiverAcceptsNewLeaseAfterSenderCachedSessionDisconnect. Raw xcresults and device logs remain in protected local storage; no device identifiers, credentials or audio are published.
