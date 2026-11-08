# Physical real-time audio test, 2026-11-08

Tracking: [Issue #54](https://github.com/dennomusooffice/koeon-client/issues/54), [PR #55](https://github.com/dennomusooffice/koeon-client/pull/55).

## Scope and acceptance criteria

The owner authorized autonomous physical tests with no fixed end time. Devices: OPPO A303OP and iPhone 17 Pro Max. Source of distributed binaries: `44b6eb3cb68b508577c14fc2ff34c11ff945ed6f`. iOS installed build is 1.0 (2026110803). OPPO initially had 1.0.13 (14); it was updated in place to 1.0.14 (15).

OPPO default transport was CELLULAR, radio reported LTE, Wi-Fi was off. Carrier speed restriction is owner-reported; actual available bandwidth was not measured or independently shaped. Android effective Opus setting was 12kbps. iPhone initially used 24kbps; selecting 12kbps requires reconnect before it becomes effective.

Criteria: five successful transmissions each direction; preparation target <=2s, failure >5s; release recovery <=3s; no stuck transmission after short/rapid presses; receive after 1/5-minute screen lock; network recovery <=30s or explicit recoverable error. Sound intelligibility, clipping and real acoustic latency require listening; UI READY and PCM callbacks alone are insufficient.

## Observed results

| Scenario | Evidence | Interpretation |
| --- | --- | --- |
| Initial OPPO to iPhone, 8-second PTT | Floor 202ms; readiness wait 507ms; Android microphone samples present; final READY, no TX error. iPhone first PCM at 20:21:05 JST, with runtime recreation around that time. Owner heard Mac TTS only, not iPhone output | Audibility failed in this setup; PCM callback does not establish successful acoustic delivery |
| OPPO short presses: 100/300/500ms | Each returned READY/IDLE; no last TX error | Cancellation/release checks passed; does not demonstrate audibility of short speech |
| OPPO LTE disabled for 8 seconds, then restored | OFFLINE while disabled. OFFLINE at 2344ms after enable; READY at 6625ms. Mobile data restored ON, Wi-Fi remained OFF | Reconnect completed within the 30-second criterion; 6625ms is an observation upper bound, not an exact transition timestamp |
| Three 3-second OPPO presses after LTE restoration | Each returned READY | Next-transmission/release state checks passed; receiver audibility not assessed |
| Re-enrolled iPhone to OPPO, 10-second PTT, 12kbps | iPhone PTT-down to TALKING 687ms, Floor 58ms, RX_READY 500ms, PTT-up to READY 360ms. Floor renew 9/9, terminal cleanup PASS. Android received START and published RX_READY. Owner heard no OPPO output | Control and TX state passed; audibility failed. Manual speech calibration requested to separate microphone pickup of Mac TTS from product-path failure |
| Live subscription during a further 20-second iPhone TX | OPPO showed one remote audio track in all four observations, with Speakerphone route | Subscription exists during transmission. This does not prove nonzero received audio, hardware playout or intelligibility |

## Test-harness error and blocker

After iPhone diagnostics, the app's scroll position had changed. The test operator reused an old screen coordinate intending POWER OFF but activated the user-change button, clearing local enrollment. This was an operator/harness error, not a spontaneous application failure. The owner was informed and re-enrolled the original user/channel; testing resumed. State-changing actions now identify the control from the current UI and verify the result; no stale coordinate reuse.

The first iOS quality menu actions also required explicit post-action verification because UI automation reported transient/stale elements. No successful setting transition is inferred solely from a command returning success.

Opening the iPhone diagnostic reader can background KOEON and cause runtime reconstruction. A zero remote-track count observed after diagnostic collection is therefore not evidence that no track was subscribed during transmission. The live subscription test above avoids switching the transmitting iPhone app during observation.

OPPO system audio inspection showed unmuted voice-call output, speaker volume 9/9; media speaker volume was 1/16. The selected WebRTC playout stream was not independently established, so the media-volume difference remains a possible test variable rather than a confirmed cause. No system volume was changed.

## Remaining acceptance

Both-direction repetition, locked-screen audio, Bluetooth, calibrated latency, acoustic intelligibility and multiple simultaneous receivers remain unverified. Overall intercom acceptance has **not** passed. Raw JSON/logs remain private; only sanitized evidence is published. Latest progress and restoration status are recorded in Issue #54.
