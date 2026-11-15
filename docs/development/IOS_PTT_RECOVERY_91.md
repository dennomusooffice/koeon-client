# Issue #91: settled PTT recovery

2026-11-15. Baseline bf43c5a, observed iOS 1.0(2026111304).

Requirement: recover ERROR and stale BUSY without restarting; never bypass Floor ownership, microphone-off confirmation or Apple's release. Scope is iOS recovery; no automatic transmission or authorization changes.

Private device journal (1,524 records) shows CONNECTED/RX_IDLE with PTT ERROR persisting over 20 minutes. Apple stop error 5 is transmissionNotFound. Existing classification already marks it recoverable and release complete. The journal does not expose all release flags, so it cannot prove one exclusive root cause.

Identified recovery gap: resetAfterReconnect is called on a reconnect event, while asynchronous safety cleanup may complete later or its mute retry may fail. Normal authoritative Floor polling did not retry this cleanup when no own lease remained. Add a retry on current free/released Floor only, with connected Room, ready audio, and idle Apple gate or rearming gate with Apple release confirmed. Existing controller guards reject an active press, acquisition, terminal task or owned lease. Confirm cleanup before completing rearming, and fence results by current Floor context. Polling supplies subsequent attempts if a transient mute failure persists.

BUSY reconciliation now accepts released as well as available. Valid remote ownership remains blocked. This addresses a code path discrepancy; the user's BUSY_REMOTE episode has not yet been reproduced independently.

Acceptance / STOP CONDITION: safe recovery checks, full iOS tests, sanitized GitHub record; device reproduction and candidate verification must be reported separately. Do not declare field resolution from unit tests.

Validation: arm64 iOS Simulator suite 281 cases, 280 passed / 1 dedicated SFU test skipped / 0 failures. Added checks for free/released Floor, Apple release pending, active Apple transmission, disconnected transport, unavailable audio and legitimate busy Floor. Existing mute-failure and retained-lease recovery tests pass. An initial x86_64 build failed to resolve LiveKit; standard arm64 retry passed.

Implementation and simulator verification complete for this candidate. Not distributed, not device-verified, not merged. Next: verify the collected failing device state with the candidate, including interruption/reconnect timing and remote Floor transitions. Preserve field enrollment and evidence. No private journal or audio is committed.
