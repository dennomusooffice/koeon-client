# Physical real-time audio test, 2026-11-08

Tracking: [Issue #54](https://github.com/dennomusooffice/koeon-client/issues/54), [PR #55](https://github.com/dennomusooffice/koeon-client/pull/55).

## Scope and acceptance criteria

The owner authorized autonomous physical tests with no fixed end time. Devices: OPPO A303OP (Android 14 / API 34) and iPhone 17 Pro Max (iOS 26.6.2), USB powered. Source of distributed binaries: `44b6eb3cb68b508577c14fc2ff34c11ff945ed6f`. iOS installed build is 1.0 (2026110803). OPPO initially had 1.0.13 (14); it was updated in place to 1.0.14 (15).

OPPO default transport was CELLULAR, radio reported LTE, Wi-Fi was off. Carrier speed restriction is owner-reported; actual available bandwidth was not measured or independently shaped. Android effective Opus setting was 12kbps. iPhone initially used 24kbps; selecting 12kbps requires reconnect before it becomes effective.

After re-enrollment, iPhone diagnostics verified applied `TELEPHONE_12K`, 12000bps, DTX and RED enabled. Native ICE candidate protocol/packet loss/jitter are not exposed by this field JSON, so the device trial does not independently prove UDP selection or actual wire bitrate. Do not substitute the emulator UDP result for a device measurement.

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
| Human voice calibration, iPhone to OPPO | Owner spoke directly into iPhone after the cue and confirmed hearing their voice from OPPO | Human-voice delivery succeeded. Earlier Mac-TTS inaudibility cannot be treated as proof of a product audio-path failure; acoustic test injection was not validated |
| Human voice calibration, OPPO to iPhone | Owner confirmed clear iPhone output with no clipping | Human-voice delivery succeeded in the reverse direction |
| OPPO screen off for at least one minute, iPhone human-voice TX | OPPO sleep was initiated and `Dozing` confirmed; owner then reported clear output with no clipping, without operating OPPO | Limited background reception passed on LTE at 12kbps; not a long-duration or battery-only acceptance result |
| iPhone locked for more than five minutes, five OPPO human-voice transmissions | CoreDevice lock confirmed before wait and again after 327 seconds. Owner reported 4/5 received, with only the first inaudible | Background first-reception criterion failed. Unlike the Mac-TTS cases, this is a human-voice failure requiring investigation; initial sender TALKING was not independently captured |

## Test-harness error and blocker

After iPhone diagnostics, the app's scroll position had changed. The test operator reused an old screen coordinate intending POWER OFF but activated the user-change button, clearing local enrollment. This was an operator/harness error, not a spontaneous application failure. The owner was informed and re-enrolled the original user/channel; testing resumed. State-changing actions now identify the control from the current UI and verify the result; no stale coordinate reuse.

The first iOS quality menu actions also required explicit post-action verification because UI automation reported transient/stale elements. No successful setting transition is inferred solely from a command returning success.

Opening the iPhone diagnostic reader can background KOEON and cause runtime reconstruction. A zero remote-track count observed after diagnostic collection is therefore not evidence that no track was subscribed during transmission. The live subscription test above avoids switching the transmitting iPhone app during observation.

OPPO system audio inspection showed unmuted voice-call output, speaker volume 9/9; media speaker volume was 1/16. The selected WebRTC playout stream was not independently established, so the media-volume difference remains a possible test variable rather than a confirmed cause. No system volume was changed.

## Remaining acceptance

Both-direction repetition, Bluetooth, calibrated latency, detailed intelligibility and multiple simultaneous receivers remain incomplete. Overall intercom acceptance has **not** passed: the first human-voice reception after the long iPhone lock failed. The earlier Mac-TTS cases alone do not establish a product defect. Raw JSON/logs remain private; only sanitized evidence is published. Latest progress and restoration status are recorded in Issue #54.

At the first collection stop, iPhone auto-lock was verified restored to 30 seconds. Android remained at 30 seconds, stay-on 0, Wi-Fi OFF, mobile data ON. The diagnostic helper installed for this task was removed and the UI test session was closed. Further human-voice/lock acceptance continues under the owner's authorization with no specified end time.

## Long-lock failure evidence

The user's copied iPhone diagnostic at 21:00:16 JST was saved without replacing the clipboard. Breadcrumbs still contained `RUNTIME_CONNECT_FAILED` and `RUNTIME_FAILED_LIVEKIT_CONNECT` at 20:50:15 JST, with listening retained. These timestamps precede the five-transmission sequence and are **not** evidence that the same failure caused its first miss. The last successful receive and foreground recovery had replaced several current diagnostic fields.

A second long-lock trial therefore uses exactly one transmission, explicit sender TALKING confirmation, read-only Android UI observation and per-process log capture, followed immediately by copying the receiver diagnostic. No POWER operation is used between the failure and collection.

## Single-transmission long-lock reproduction

The owner confirmed one OPPO transmission after the cue/TALKING instruction was inaudible on the locked iPhone. The copied receiver JSON (21:32:40 JST) was successfully preserved, without asking for another transmission or POWER cycle. This reproduces the first-reception problem separately from the earlier five-transmission sequence. The Android UI observer had already ended before this transmission; it cannot independently verify this send.

The receiver breadcrumbs contain `APP_START` at 21:32:16, `APPLE_DID_ACTIVATE` at 21:32:17 and deactivation at 21:32:24. Previous-run lifecycle was BACKGROUND and termination classification UNKNOWN. This supports a cold-start receive path; it does not establish a crash or the reason for process termination. A wake attempt spans 21:32:16–21:32:22.

Retained RX consistency events show no observed PCM, a connected room, resolved participant and subscribed track at elapsed 4324/4339/4348 ms. Further events occur at 4356/4362 ms after the active subscription/generation state disappears. Thus five recovery-stage observations span only 38 ms. Current first-PCM at 21:32:34 and foreground reconnect fields belong to the later foreground recovery and must not be presented as successful locked reception.

Code inspection identifies a hypothesis to test: `evaluateRxDivergenceWatchdog` defers while incoming/buffered discovery owns recovery, while the consistency guard uses deadlines of 250/750/1500/2500/4000 ms from the original RX start. If evaluation resumes after four seconds, all thresholds are already overdue and recovery levels can advance rapidly. The observed clustering is consistent with this; neither the scheduling mechanism nor the original PCM absence has yet been established as the root cause. No product fix or new distribution is claimed.

Collection limitation: Android diagnostic navigation initially failed to move the page. Inspection showed the central swipe crossed the PTT region. It may have generated additional short PTT input after the failed trial; the original sender-last-attempt fields must therefore not be treated as uncontaminated evidence. The receiver clipboard had already been preserved before this navigation. Subsequent scrolling uses the outer edge, and no additional speech trial was requested.

Sender JSON collection did not complete because the copy control could not be reliably reached. The temporary Android field-probe package was uninstalled; the iPhone UI session and task-owned Appium server were stopped. Android screen timeout remained 30000 ms, Wi-Fi OFF and mobile data ON. iPhone auto-lock was not changed from its previously verified 30 seconds during this collection. The confirmed single-shot failure remains open; subsequent investigation should preserve sender instrumentation before the next trial and examine cold-start audio activation/subscription plus recovery scheduling.

## Fix for cold-receive recovery, 2026-11-08

The saved failure trace exposed a reproducible recovery defect, rather than proving the original transport/decoder failure. Replaying elapsed times 4324, 4339, 4348, 4356 and 4362 ms against the pre-fix `RxConsistencyGuard` advanced all five levels, including destructive runtime replacement and terminal cleanup. The new regression produced four unexpected recovery actions and an attempt-count mismatch (5 versus 1). This confirms why delayed evaluation could deny recovery a useful opportunity. It does not explain why PCM was initially absent, nor why the previous process ended.

Implemented changes:

- Retain the usual 250/750/1500/2500/4000 ms schedule when work is timely, but enforce the interval between stages from the preceding recovery's actual completion. Reconciliation callbacks cannot restart the ladder, stale generation completions cannot delay a new RX, and the ladder still terminates after five attempts.
- Do not enqueue another recovery while one is executing. Re-arm the watchdog after completion; cancellation and runtime-generation fences remain. Do not schedule it during shutdown.
- Legacy discovery no longer blocks the first two non-destructive RTP rebind/subscription attempts. Subscription teardown and fresh resume still wait for legacy discovery, preserving older BATv1 receivers.
- Preserve current-runtime authenticated RTP START evidence as well as BATv1 evidence. The former keep-runtime condition required a buffered generation even when PCM existed, so RTP could never satisfy it. Keep channel, sender, speaker, lease and runtime validation; cached CONNECTED alone is still insufficient.
- If authenticated RTP START arrived before legacy discovery was installed, skip that now-unnecessary lookup and re-arm recovery. BATv1 descriptor matching still requires a buffered generation.

No codec, bitrate, RX_READY ceiling, start-cue ordering, 180 ms transmit tail, receiver drain, Apple audio-session ownership or Android product code changed. The released builds remain iOS 1.0 (2026110803) and Android 1.0.14 (15), source `44b6eb3cb68b508577c14fc2ff34c11ff945ed6f`; this fix is not distributed.

Physical acceptance remains open: repeat first reception after long lock and process cold wake, including a missed control START, then both-direction speech and Bluetooth. Simulator regression cannot reproduce Apple's locked-device PushToTalk activation or prove actual audibility. Preserve the first failure before further PTT and avoid the prior Android scroll harness. Issue #54 must stay open until this evidence exists.

Final automatic validation: iOS 27.2 Simulator (arm64), `SIMULATOR_UDID=<local simulator> bash scripts/macos-build.sh ios-test`: **306 executed, 304 passed, 2 opt-in probes skipped, 0 failures**, with successful app/test build. Four new cases cover the field's delayed recovery timeline, completion grace with stale-generation rejection and finite escalation, RTP matching with foreign identity/lease rejection, and safe recovery while legacy discovery is pending. Existing short-burst, drain, cancellation, audio-activation and recovery tests remained green. `git diff --check` passed. Local logs: `.build/macos/ios-cold-rx-red.log` (pre-fix assertion evidence) and `.build/macos/ios-cold-rx-verified.log` (final full regression). No physical device operations, TestFlight upload or merge were performed for this fix.
