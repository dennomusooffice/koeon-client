# Issue #91: settled PTT recovery

2026-11-15. Baseline bf43c5a, observed iOS 1.0(2026111304).

Requirement: recover ERROR and stale BUSY without restarting; never bypass Floor ownership, microphone-off confirmation or Apple's release. Scope is iOS recovery; no automatic transmission or authorization changes.

Private device journal (1,524 records) shows CONNECTED/RX_IDLE with PTT ERROR persisting over 20 minutes. Apple stop error 5 is transmissionNotFound. Existing classification already marks it recoverable and release complete. The journal does not expose all release flags, so it cannot prove one exclusive root cause.

Identified recovery gap: resetAfterReconnect is called on a reconnect event, while asynchronous safety cleanup may complete later or its mute retry may fail. Normal authoritative Floor polling did not retry this cleanup when no own lease remained. Add a retry on current free/released Floor only, with connected Room, ready audio, and idle Apple gate or rearming gate with Apple release confirmed. Existing controller guards reject an active press, acquisition, terminal task or owned lease. Confirm cleanup before completing rearming, and fence results by current Floor context. Polling supplies subsequent attempts if a transient mute failure persists.

BUSY reconciliation now accepts released as well as available. Valid remote ownership remains blocked. This addresses a code path discrepancy; the user's BUSY_REMOTE episode has not yet been reproduced independently.

Acceptance / STOP CONDITION: safe recovery checks, full iOS tests, sanitized GitHub record; device reproduction and candidate verification must be reported separately. Do not declare field resolution from unit tests.

Validation: arm64 iOS Simulator suite 281 cases, 280 passed / 1 dedicated SFU test skipped / 0 failures. Added checks for free/released Floor, Apple release pending, active Apple transmission, disconnected transport, unavailable audio and legitimate busy Floor. Existing mute-failure and retained-lease recovery tests pass. An initial x86_64 build failed to resolve LiveKit; standard arm64 retry passed.

Initial checkpoint before distribution: implementation and simulator verification completed. At that checkpoint not distributed, not device-verified, not merged. Next: verify the collected failing device state with the candidate, including interruption/reconnect timing and remote Floor transitions. Preserve field enrollment and evidence. No private journal or audio is committed.

## Android follow-up

Android ERROR does not independently disable PTT eligibility. A separate BUSY edge case was reproduced: released Floor retaining the old lease ID did not enter drain. Added regression failed before the fix (1/14 receiver tests) and passed after treating released and available alike. Full Android unit tests and lint pass. Version 1.0.31(32) is the release candidate. Real-device equivalence is not yet verified.

## 2026-11-15 distribution and bounded device verification

iOS source 8a3178411825921a0b5c23cc2262d6900ca9eb6a was uploaded as 1.0(2026111501). App Store Connect reported VALID / IN_BETA_TESTING and assignment to both existing internal groups. Installed version was verified on the connected iPhone. External group/review availability is not established by this record.

A bounded airplane-mode interruption returned to READY without POWER cycling or process restart. Private journal shows RECONNECTING/ERROR to IDLE with runtime rebuilds within the session. This is recovery evidence, not reproduction of the original twenty-minute stuck condition.

Following the owner's production-channel restriction, subsequent peer tests used only the designated isolated test channel. The owner explicitly authorized adding that channel membership to the simulator account; one additive same-workspace membership was applied with an operator audit record, preserving other memberships. No PTT was sent on the production channel.

TestFlight 2026111501 iPhone versus Android API35 simulator (existing 1.0.23-ui23): three finite simulator PTT holds each produced iPhone BUSY_REMOTE followed by READY. One reverse iPhone PTT hold produced simulator BUSY REMOTE followed by READY; iPhone also returned to READY. No iPhone POWER cycling or process restart was used. These observations verify UI/control transitions, not human audio intelligibility or comprehensive field stability. Raw journals and UI snapshots remain private.

Remaining: original persistent-error reproduction, long-duration/background/route-change coverage, Android 1.0.31(32) signing/distribution and candidate-level peer regression. Issue remains open; main merge not performed.
