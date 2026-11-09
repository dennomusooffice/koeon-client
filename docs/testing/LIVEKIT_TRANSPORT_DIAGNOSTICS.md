# Android reconnect transport diagnostics

Issue #57: reduced Android 14/15/16 lab reproduced a sender reconnect during synthetic speech on 1.0.19 (20). Existing journal captures RECONNECTING and safe TX cancellation but not the transport that failed. This change adds observability, not a claimed reconnect fix.

Internal candidate 1.0.20 (21) classifies the pinned LiveKit Android 2.28.0 SDK's publisher/subscriber peer-connection changes, unscoped ICE changes, signal close/ping timeout, and network-available reconnect. Categories go to `TRANSPORT` journal events (`data.reason`) and `KOEONTransport` logcat. Inspect ordering before RECONNECTING; a later signal reconnect is a recovery step, not necessarily the initiating cause. ICE messages do not identify publisher/subscriber and are deliberately labeled UNSCOPED.

The application replaces the SDK logger before enabling verbose SDK message generation. Only fixed allowlisted categories are retained. SDP, token/URL, ICE addresses, raw server close reasons and exception text are discarded; native WebRTC logging remains disabled. Unknown/new SDK formats are ignored, so revalidate mapping when updating the SDK. KOEON owns one Room per process; this global SDK logger must be reviewed before adding another SDK consumer. There is transient SDK formatting cost, but no raw log persistence or new periodic stats polling.

TX remains cancelled on connection loss. Do not resume microphone transmission merely because connectivity returns. Version 1.0.20 is diagnostic-only until the observed reconnect trigger is established and a separate functional fix is verified.

Validation: mapper tests cover publisher/subscriber discrimination, signal timeout, unknown formats and sensitive payload rejection; full Android unit suite executed before candidate build. Exact commit, build verification and reduced-device result are recorded in the linked PR/Issue. Physical-device or general stability acceptance is not implied.

Follow-up internal candidate 1.0.21 (22) also records a numeric WebSocket close code and an allowlisted server LEAVE reason. This distinguishes server-directed media failure, duplicate identity and shutdown without retaining the raw close reason. The pinned 2.28.0 AAR was checked for the mapped message prefixes. Unknown reasons are discarded. Build 21 remains historical diagnostic evidence; neither build is a claimed functional fix.
