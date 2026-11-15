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

### Extended isolated-channel recovery trial plan

Owner authorized continued iPhone waiting/lock/disconnection tests and Android parity checks on 2026-11-15. Scope: existing recovery fix, isolated test channel only, simulator peer; no production-channel PTT. Dependencies: authorized channel membership, connected device, automation and diagnostic access. Acceptance: after idle/lock/network recovery, valid new Floor permits finite TX and remote RX, legitimate BUSY clears on release, no stale ERROR; collect control and media-counter evidence separately from human listening. Test at least five minutes idle/lock and bounded network interruptions, record actual durations. No audio persistence. STOP: sixty minutes from this extension, device authentication blocker for dependent tests, loss of channel verification, or resource-limit stop; restore network changes in finally blocks. Do not claim general stability or acoustic success from UI alone.

Extended finding: Android 1.0.31(32), after a 15-second network interruption, recovered connectivity and received the peer, but a subsequent microphone start failed and left PTT ERROR across repeated heartbeats. Diagnostics: `Audio TX could not start`. Add an authoritative free/released Floor reconciliation for ERROR/BUSY, only when the same active session is connected/audio-ready, no held press/lease/transition exists, and bounded microphone-off succeeds. Recheck context after suspension; never automatically transmit. Tests must cover failed mute, invalid context, legitimate busy Floor and active TX. iPhone long-lock peer attempt had zero server Push candidates; background audio receipt remains unverified, separate from successful foreground recovery.

### Apple token scope correction

The physical iPhone diagnostic showed Apple framework JOINED but Ephemeral token Not registered after switching to the isolated channel. Server push evaluation found zero candidates. `beginJoin` explicitly discarded an in-memory token on a different channel UUID, and tests enforced this assumption. Apple documents that the ephemeral token is provided after PTChannelManager initialization, becomes active on joining, and must not be cached to storage: https://developer.apple.com/documentation/pushtotalk/ptchannelmanagerdelegate/channelmanager(_:receivedephemeralpushtoken:). The prior per-channel-discard assumption is inconsistent with that manager-level lifecycle. Correct the binding to retain only the current manager's in-memory token, require completed Apple join, and bind registration to the new authorized backend session/channel. Leave remains ineligible; token rotation, in-flight registration generation checks, server membership authority and explicit old-session unregistration remain unchanged. No token persistence or cross-session authorization reuse. Device correlation supports this cause but correction still requires on-device background acceptance.

Validation update: Android 1.0.32(33), source 623098a, signed candidate passed the repeated 15-second network interruption scenario: post-recovery TX journal reached TRANSMITTING/RELEASING/IDLE; peer BUSY_REMOTE observed and both UIs READY at final re-read. One UI hierarchy collection failed transiently; final state was independently re-read and journal collected. No restart or POWER cycling during the scenario. This single pass does not guarantee all microphone failures are resolved. iOS manager-token scope correction: 281 simulator tests, 280 pass / 1 dedicated SFU skip / 0 failures. New candidate still requires distribution and background device validation.
