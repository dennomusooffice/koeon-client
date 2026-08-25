import SwiftUI
import MediaPlayer

struct RootView: View {
    @EnvironmentObject private var session: IntercomSessionController
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var showQRScanner = false
    @State private var inviteInput = ""
    @State private var pttTouchEdgeGate = AppPttTouchEdgeGate()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    brand
                    if session.isJoined { joinedView } else { selectionView }
                    if let error = session.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("KOEON")
            .toolbar {
                Button("Settings") { showSettings = true }
                Button("Diagnostics") { showDiagnostics = true }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .fullScreenCover(isPresented: $showQRScanner) {
                ZStack(alignment: .topTrailing) {
                    InviteQRScannerView(
                        onCode: { value in
                            showQRScanner = false
                            Task { await session.enroll(inviteTokenOrURL: value) }
                        },
                        onError: { message in
                            showQRScanner = false
                            inviteInput = ""
                            session.reportEnrollmentError(message)
                        }
                    )
                    Button("Close") { showQRScanner = false }
                        .buttonStyle(.borderedProminent)
                        .padding()
                }
                .ignoresSafeArea()
            }
            .task { await session.loadFixture() }
        }
        .tint(KOEONPalette.cyan)
        .preferredColorScheme(.dark)
    }

    private var brand: some View {
        VStack(spacing: 4) {
            Text("KOEON").font(.system(size: 34, weight: .black, design: .rounded)).tracking(3)
            Text("声を、いつでもONに。").font(.headline).foregroundStyle(.secondary)
        }
    }

    private var selectionView: some View {
        VStack(spacing: 16) {
            if session.enrollmentRequired {
                Text("KOEONを利用登録").font(.title2.bold()).foregroundStyle(KOEONPalette.cyan)
                Text("運営から届いた招待コードを入力してください。")
                    .foregroundStyle(.secondary)
                TextField("招待コードを入力", text: $inviteInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .textFieldStyle(.roundedBorder)
                Button("この端末を登録") {
                    Task { await session.enroll(inviteTokenOrURL: inviteInput) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(inviteInput.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 || session.isLoading)
                DisclosureGroup("QRコードを使う場合") {
                    Button { showQRScanner = true } label: {
                        Label("QRコードを読み取る", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else {
            Picker("User", selection: Binding(
                get: { session.selectedUserId ?? "" },
                set: { session.selectedUserId = $0 }
            )) {
                ForEach(session.fixture?.users ?? []) { user in
                    Text("\(user.name) — \(user.role.rawValue)").tag(user.id)
                }
            }
            .pickerStyle(.menu)

            Picker("Channel", selection: Binding(
                get: { session.selectedChannelId ?? "" },
                set: { session.selectedChannelId = $0 }
            )) {
                ForEach(session.fixture?.channels ?? []) { channel in
                    Text(channel.name).tag(channel.id)
                }
            }
            .pickerStyle(.menu)

            Button {
                Task { await session.join() }
            } label: {
                Label("POWER ON · START", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.isLoading || session.selectedUser == nil || session.selectedChannel == nil)
            Toggle("Headset PTT Button", isOn: Binding(
                get: { session.pushToTalk.headsetPttEnabled },
                set: { session.setHeadsetPttEnabled($0) }
            ))
            Button("この端末のユーザーを変更") {
                Task { await session.resetDeviceAssignment() }
            }
            .buttonStyle(.bordered)
            .disabled(session.isLoading)
            }
        }
        .padding()
        .background(KOEONPalette.lcd, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(KOEONPalette.cyan.opacity(0.35)))
    }

    private var joinedView: some View {
        VStack(spacing: 18) {
            statusCard
            if session.audio.interruption.state != .ready {
                VStack(spacing: 8) {
                    Text("AUDIO INTERRUPTED").font(.headline).foregroundStyle(.orange)
                    Text(session.audio.interruption.state == .recovering
                         ? "音声を自動復旧しています…"
                         : "通話・OS音声割り込み中はPTTを利用できません。")
                        .font(.footnote)
                    if session.audio.interruption.state == .recoveryFailed {
                        Button("音声を再接続") { session.retryAudioRecovery() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
            pttButton
            Button("POWER OFF", role: .destructive) {
                Task { await session.leave(powerOff: true) }
            }
            .buttonStyle(.bordered)
            .disabled(session.isLoading)
            Toggle("Headset PTT Button", isOn: Binding(
                get: { session.pushToTalk.headsetPttEnabled },
                set: { session.setHeadsetPttEnabled($0) }
            ))
            Button("この端末のユーザーを変更", role: .destructive) {
                Task { await session.resetDeviceAssignment() }
            }
            .buttonStyle(.bordered)
            .disabled(session.isLoading || session.pttSnapshot.state != .idle)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current = session.joinedSession?.channel.id {
                HStack {
                    Button { switchRelative(-1, current: current) } label: { Image(systemName: "chevron.left") }
                        .disabled(session.operationalState != .active)
                    Spacer()
                    Text(session.joinedSession?.channel.name ?? "—")
                        .font(.title2.monospaced().bold()).foregroundStyle(KOEONPalette.cyan)
                    Spacer()
                    Button { switchRelative(1, current: current) } label: { Image(systemName: "chevron.right") }
                        .disabled(session.operationalState != .active)
                }
                .controlSize(.large)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ChannelSwitchPolicy.ordered(session.fixture?.channels ?? [])) { channel in
                            Button(channel.id == current ? "\(channel.name) · ACTIVE" : channel.name) {
                                Task { await session.switchChannel(to: channel.id) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(channel.id == current || session.operationalState != .active)
                        }
                    }
                }
            }
            valueRow("System", session.operationalState.rawValue)
            valueRow("Connection", session.room.connectionState.rawValue)
            valueRow("Channel", session.joinedSession?.channel.name ?? "—")
            valueRow("User", session.joinedSession?.user.name ?? "—")
            valueRow("Current speaker", session.room.currentSpeaker ?? "None")
            valueRow("PTT", session.pttSnapshot.state.rawValue)
            valueRow("RX", session.rxSnapshot.state.rawValue)
            valueRow("Audio route", session.audio.route.rawValue)
            valueRow("Audio availability", session.audio.interruption.state.rawValue)
            valueRow("Participants", session.room.participantNames.joined(separator: ", "))
            if session.pttSnapshot.state == .busy {
                Text("BUSY — \(session.pttSnapshot.ownerName ?? "another user") is transmitting")
                    .font(.headline).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(KOEONPalette.lcd, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(KOEONPalette.cyan.opacity(0.35)))
    }

    private var pttButton: some View {
        let rxOnly = session.joinedSession?.canPublish != true
        let inputPressed = session.hapticSnapshot.inputPressed
        let semantic = session.pttSemanticState
        let fill: Color = switch semantic {
        case .ready: Color(red: 0.12, green: 0.72, blue: 0.35)
        case .talking: Color(red: 0.04, green: 0.90, blue: 0.38)
        case .busyRemote, .preparing: Color(red: 1.0, green: 0.66, blue: 0.12)
        case .error: Color.red
        case .recovering, .offline, .rxOnly: Color.gray
        }
        let icon = switch semantic {
        case .talking: "waveform"
        case .busyRemote: "person.wave.2.fill"
        case .preparing: "hourglass"
        case .error: "exclamationmark.triangle.fill"
        case .recovering: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .rxOnly: "ear"
        case .ready: "mic.fill"
        }
        return ZStack {
            Circle().fill(fill.gradient)
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 50))
                Text(semantic == .ready ? "PTT · READY" : semantic.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.title3.bold())
            }
            .foregroundStyle(.white)
        }
        .frame(width: 220, height: 220)
        .scaleEffect(inputPressed ? 0.97 : 1)
        .offset(y: inputPressed ? 3 : 0)
        .shadow(radius: inputPressed ? 3 : 8, y: inputPressed ? 1 : 4)
        .animation(.easeOut(duration: 0.08), value: inputPressed)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if pttTouchEdgeGate.changed() { session.pttDown() }
            }
            .onEnded { _ in
                if pttTouchEdgeGate.ended() { session.pttUp() }
            })
        .accessibilityLabel(rxOnly ? "Receive only" : "Push to talk")
        .accessibilityValue(semantic.rawValue)
        .accessibilityHint(rxOnly ? "This user cannot publish audio" : "Hold to transmit, release to stop")
        .allowsHitTesting(!rxOnly && session.canPressPTT)
    }

    private func switchRelative(_ direction: Int, current: String) {
        guard let target = ChannelSwitchPolicy.adjacent(session.fixture?.channels ?? [], currentId: current, direction: direction) else { return }
        Task { await session.switchChannel(to: target) }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var session: IntercomSessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("音声品質") {
                    Picker("送信音声", selection: Binding(
                        get: { session.selectedAudioPublishProfile },
                        set: { session.setAudioPublishProfile($0) }
                    )) {
                        ForEach(AudioPublishProfile.allCases, id: \.self) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    row("選択中", session.selectedAudioPublishProfile.displayName)
                    row("現在のRoom", session.appliedAudioPublishProfile?.displayName ?? "未接続")
                    Text("標準は24 kbpsです。通信が不安定な場所では12 kbps、音質比較には48 kbpsを利用できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if session.isJoined {
                        Text("設定は保存されました。現在のRoomは変更せず、次回のPOWER ONから反映されます。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

private enum KOEONPalette {
    static let cyan = Color(red: 34 / 255, green: 223 / 255, blue: 243 / 255)
    static let lcd = Color(red: 3 / 255, green: 26 / 255, blue: 32 / 255)
    static let control = Color(red: 9 / 255, green: 38 / 255, blue: 54 / 255)
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var session: IntercomSessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Field Lab · Internal") {
                    Picker("APP_TX_PATH", selection: $session.appTxPath) {
                        ForEach(AppTxPath.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("RX_READY_POLICY", selection: $session.rxReadyPolicy) {
                        ForEach(RxReadyPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("RESTORE_PATH", selection: $session.restorePath) {
                        ForEach(RestorePath.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("RX_START_CUE", selection: $session.rxStartCueMode) {
                        ForEach(RxStartCueMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Volume button probe", selection: $session.volumeProbeMode) {
                        ForEach(IOSVolumeProbeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Text("iOS volume PTT is observe-only: IOS_VOLUME_BUTTON_PTT_UNSUPPORTED_RELIABLY")
                        .font(.caption).foregroundStyle(.secondary)
                    SystemVolumeControl().frame(height: 34)
                    row("Observed output volume", String(format: "%.2f", session.audio.outputVolume))
                    row("Last observed", format(session.audio.outputVolumeObservedAt))
                    Button("Copy Field Diagnostic JSON") { session.copyFieldDiagnosticJSON() }
                    row("Copy result", session.fieldDiagnosticCopyResult)
                }
                Section("Input Gain · TASK003G6") {
                    let gain = session.inputGain.snapshot()
                    Picker("Mode", selection: Binding(
                        get: { gain.mode },
                        set: { session.setInputGainMode($0) }
                    )) {
                        ForEach(InputGainMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Slider(
                        value: Binding(
                            get: { Double(session.inputGain.snapshot().manualGainDb) },
                            set: { session.setManualInputGain(Float($0)) }
                        ),
                        in: -6...12,
                        step: 1
                    )
                    row("Route / effective", "\(gain.route) / \(String(format: "%.1f", gain.effectiveGainDb)) dB")
                    row("RMS / Peak", "\(gain.rmsDbfs.map { String(format: "%.1f", $0) } ?? "Unavailable") / \(gain.peakDbfs.map { String(format: "%.1f", $0) } ?? "Unavailable")")
                    row("Limiter hits", "\(gain.limiterHits)")
                    Button("Calibrate 3 seconds") { session.startInputGainCalibration() }
                    Button("Reset route profile", role: .destructive) { session.resetInputGainProfile() }
                    Text("TASK003G6B_AUDIO_ROUTE_SELECTION").font(.caption2).foregroundStyle(.secondary)
                }
                Section("Session") {
                    row("Connection", session.room.connectionState.rawValue)
                    row("Room", session.joinedSession?.roomName ?? "—")
                    row("User", session.joinedSession?.user.name ?? "—")
                    row("Channel", session.joinedSession?.channel.name ?? "—")
                    row("Participants", session.room.participantNames.joined(separator: ", "))
                    row("Current speaker", session.room.currentSpeaker ?? "None")
                    row("Reconnect count", "\(session.room.reconnectCount)")
                    row("Uptime", "\(session.sessionUptimeSeconds)s")
                    row("Network", session.network.pathDescription)
                    row("App lifecycle", session.appLifecycleState)
                }
                Section("PTT / Floor") {
                    row("PTT state", session.pttSnapshot.state.rawValue)
                    row("ptt_eligible", session.pttEligible.description)
                    row("ptt_block_reason", session.pttBlockReason)
                    row("ptt_semantic_state", session.pttSemanticState.rawValue)
                    row("Lease", session.pttSnapshot.leaseId.map { String($0.prefix(8)) + "…" } ?? "None")
                    row("Lease expiry", format(session.pttSnapshot.leaseExpiresAt))
                    row("Max TX expiry", format(session.pttSnapshot.maxTxExpiresAt))
                    row("Start cue", session.pttSnapshot.startCueResult.displayValue)
                    row("End cue", session.pttSnapshot.endCueResult.displayValue)
                    row("Control START", session.pttSnapshot.controlStartResult)
                    row("Control END", session.pttSnapshot.controlEndResult)
                    row("Apple PTT request gate", session.pttRequestGateState.rawValue)
                    row("Status cue", session.lastStatusCueResult)
                    row("ptt_down_at", format(session.pttSnapshot.pttDownAt))
                    row("floor_granted_at", format(session.pttSnapshot.floorGrantedAt))
                    row("control_start_sent_at", format(session.pttSnapshot.controlStartSentAt))
                    row("cue_start_at", format(session.pttSnapshot.cueStartAt))
                    row("cue_end_at", format(session.pttSnapshot.cueEndAt))
                    row("track_enabled_at", format(session.pttSnapshot.trackEnabledAt))
                    row("Floor latency", latency(session.pttSnapshot.floorLatencyMilliseconds))
                    row("Local enable latency", latency(session.pttSnapshot.localEnableLatencyMilliseconds))
                    row("rx_ready_wait_started_at", format(session.pttSnapshot.rxReadyWaitStartedAt))
                    row("rx_ready_first_at", format(session.pttSnapshot.rxReadyFirstAt))
                    row("rx_ready_all_at", format(session.pttSnapshot.rxReadyAllAt))
                    row("rx_ready_wait_ms", latency(session.pttSnapshot.rxReadyWaitMilliseconds))
                    row("rx_ready_expected/received/late", "\(session.pttSnapshot.rxReadyExpectedCount) / \(session.pttSnapshot.rxReadyReceivedCount) / \(session.pttSnapshot.rxReadyLateCount)")
                    row("rx_ready_timed_out", session.pttSnapshot.rxReadyTimedOut ? "Yes" : "No")
                    row("apple_begin_requested_at", format(session.appleBeginRequestedAt))
                    row("apple_did_begin_at", format(session.appleDidBeginAt))
                    row("apple_did_activate_at", format(session.appleDidActivateAt))
                    row("resume_request_at", format(session.resumeRequestAt))
                    row("resume_response_at", format(session.resumeResponseAt))
                    row("resume_livekit_connect_start", format(session.resumeLiveKitConnectStartedAt))
                    row("resume_livekit_connected", format(session.resumeLiveKitConnectedAt))
                    row("runtime_restore_reason", session.runtimeRestoreReason)
                    row("runtime_restore_decision", session.runtimeRestoreDecision)
                    row("runtime_restore_early_exit", session.runtimeRestoreEarlyExitReason)
                    row("restore_entry_connection", session.roomConnectionStateAtRestoreEntry)
                    row("restore_entry_joined_session", session.joinedSessionPresentAtRestoreEntry ? "Yes" : "No")
                    row("stale_teardown_started_at", format(session.staleRuntimeTeardownStartedAt))
                    row("stale_teardown_completed_at", format(session.staleRuntimeTeardownCompletedAt))
                    row("Haptic supported", session.hapticSnapshot.supported ? "Yes" : "No")
                    row("Haptic enabled", session.hapticSnapshot.enabled ? "Yes" : "No")
                    row("Last haptic type", session.hapticSnapshot.lastType?.rawValue ?? "Unavailable")
                    row("Last haptic at", format(session.hapticSnapshot.lastAt))
                    row("Last haptic result", session.hapticSnapshot.lastResult.rawValue)
                }
                Section("RX lifecycle") {
                    row("rx_state", session.rxSnapshot.state.rawValue)
                    row("remote_speaker_session_id", session.remoteReceiveSnapshot.remoteSpeakerSessionId ?? "Unavailable")
                    row("remote_speaker_name", session.remoteReceiveSnapshot.remoteSpeakerName ?? "Unavailable")
                    row("ptt_remote_participant_state", session.remoteReceiveSnapshot.remoteParticipantState)
                    row("remote_generation", "\(session.remoteReceiveSnapshot.remoteGeneration)")
                    row("remote_lease_prefix", session.remoteReceiveSnapshot.remoteLeasePrefix ?? "Unavailable")
                    row("remote_clear_requested_at", format(session.remoteReceiveSnapshot.remoteClearRequestedAt))
                    row("remote_clear_reason", session.remoteReceiveSnapshot.remoteClearReason ?? "Unavailable")
                    row("ptt_audio_session_active", session.audio.pushToTalkAudioSessionActive ? "Yes" : "No")
                    row("livekit_engine_availability", session.audio.liveKitEngineAvailability)
                    row("rx_audio_activity", session.remoteReceiveSnapshot.rxAudioActivity)
                    row("speaker_user_id", session.rxSnapshot.speakerUserId ?? "Unavailable")
                    row("rx_activation_requested_at", format(session.remoteReceiveSnapshot.activationRequestedAt))
                    row("rx_audio_session_activated_at", format(session.remoteReceiveSnapshot.audioSessionActivatedAt))
                    row("rx_first_audio_at", format(session.remoteReceiveSnapshot.firstAudioAt))
                    row("rx_activation_ms", latency(session.remoteReceiveSnapshot.activationMilliseconds))
                    row("rx_started_at", format(session.rxSnapshot.rxStartedAt))
                    row("rx_end_signal_at", format(session.rxSnapshot.rxEndSignalAt))
                    row("rx_drain_started_at", format(session.rxSnapshot.rxDrainStartedAt))
                    row("rx_drain_completed_at", format(session.rxSnapshot.rxDrainCompletedAt))
                    row("rx_drain_duration_ms", latency(session.rxSnapshot.rxDrainDurationMilliseconds))
                    row("rx_playout_drain_target_ms", "\(session.rxSnapshot.rxPlayoutDrainTargetMilliseconds)")
                    row("rx_end_reason", session.rxSnapshot.rxEndReason ?? "Unavailable")
                    row("floor_status_outcome", session.rxSnapshot.lastFloorStatusOutcome ?? "Unavailable")
                    row("floor_status_owner", session.rxSnapshot.lastFloorStatusOwnerUserId ?? "Unavailable")
                    row("floor_status_is_owner", session.rxSnapshot.lastFloorStatusIsOwner.map { String($0) } ?? "Unavailable")
                    row("floor_status_lease_visible", session.rxSnapshot.lastFloorStatusLeaseVisible.map { String($0) } ?? "Unavailable")
                    row("floor_reconcile_decision", session.rxSnapshot.lastFloorReconcileDecision ?? "Unavailable")
                    row("rx_control_start_received_at", format(session.rxSnapshot.rxControlStartReceivedAt))
                    row("rx_remote_participant_requested_at", format(session.rxSnapshot.rxRemoteParticipantRequestedAt))
                    row("rx_apple_audio_activated_at", format(session.rxSnapshot.rxAppleAudioActivatedAt))
                    row("rx_livekit_engine_enabled_at", format(session.rxSnapshot.rxLiveKitEngineEnabledAt))
                    row("rx_first_pcm_at", format(session.rxSnapshot.rxFirstPcmAt))
                    row("rx_control_end_received_at", format(session.rxSnapshot.rxControlEndReceivedAt))
                    row("rx_floor_end_observed_at", format(session.rxSnapshot.rxFloorEndObservedAt))
                    row("rx_last_audio_at", format(session.rxSnapshot.rxLastAudioAt))
                    row("rx_playback_completed_at", format(session.rxSnapshot.rxPlaybackCompletedAt))
                    row("rx_remote_participant_cleared_at", format(session.rxSnapshot.rxRemoteParticipantClearedAt))
                    row("control_to_apple_activate_ms", latency(session.rxSnapshot.controlToAppleActivateMilliseconds))
                    row("apple_activate_to_first_pcm_ms", latency(session.rxSnapshot.appleActivateToFirstPcmMilliseconds))
                    row("control_to_first_pcm_ms", latency(session.rxSnapshot.controlToFirstPcmMilliseconds))
                    row("end_before_apple_activate", session.rxSnapshot.endBeforeAppleActivate ? "Yes" : "No")
                    row("end_before_first_pcm", session.rxSnapshot.endBeforeFirstPcm ? "Yes" : "No")
                    row("short_burst_protection_used", session.rxSnapshot.shortBurstProtectionUsed ? "Yes" : "No")
                    row("short_burst_protection_ms", latency(session.rxSnapshot.shortBurstProtectionMilliseconds))
                    row("rx_control_event_sent_at", format(session.rxSnapshot.rxControlEventSentAt))
                    row("rx_control_clock_delta_ms", latency(session.rxSnapshot.rxControlNetworkMilliseconds))
                    row("rx_control_clock_delta_kind", "cross-clock estimate")
                    row("rx_incoming_push_at", format(session.rxSnapshot.rxIncomingPushAt))
                    row("rx_floor_to_push_clock_delta_ms", latency(session.rxSnapshot.rxFloorToPushMilliseconds))
                    row("rx_ready_sent_at", format(session.rxSnapshot.rxReadySentAt))
                    row("rx_start_cue_started_at", format(session.rxSnapshot.rxStartCueStartedAt))
                    row("rx_start_cue_completed_at", format(session.rxSnapshot.rxStartCueCompletedAt))
                    row("rx_output_latency_ms", latency(session.rxSnapshot.rxAppleOutputLatencyMilliseconds))
                    row("rx_io_buffer_ms", latency(session.rxSnapshot.rxAppleIoBufferDurationMilliseconds))
                    row("rx_audio_route", session.rxSnapshot.rxAudioRoute ?? "Unavailable")
                    row("remote_participant_cleared_at", format(session.remoteReceiveSnapshot.remoteParticipantClearedAt))
                    row("remote_resolution_failures", "\(session.remoteReceiveSnapshot.resolutionFailures)")
                    row("control_event_type", session.rxSnapshot.controlEventType ?? "Unavailable")
                    row("control_sequence", session.rxSnapshot.controlSequence.map(String.init) ?? "Unavailable")
                    row("control_event_late", session.rxSnapshot.controlEventLate ? "Yes" : "No")
                    row("rx_start_cue_result", session.rxSnapshot.startCueResult.displayValue)
                    row("rx_end_cue_result", session.rxSnapshot.endCueResult.displayValue)
                    row("duplicate/stale/preempted", "\(session.rxSnapshot.duplicateIgnored) / \(session.rxSnapshot.staleIgnored) / \(session.rxSnapshot.preempted)")
                    row("rx_generation", "\(session.rxSnapshot.generation)")
                    row("ptt_last_stop_reason", session.pttSnapshot.lastStopReason ?? "None")
                    row("floor_renew_attempt/success", "\(session.pttSnapshot.floorRenewAttemptCount) / \(session.pttSnapshot.floorRenewSuccessCount)")
                    row("floor_last_renew_result", session.pttSnapshot.floorLastRenewResult ?? "Unavailable")
                    row("control_publish_fast_ms", latency(session.pttSnapshot.controlPublishFastMilliseconds))
                    row("control_publish_reliable_ms", latency(session.pttSnapshot.controlPublishReliableMilliseconds))
                }
                Section("Audio") {
                    row("Route", session.audio.route.rawValue)
                    row("Previous route", session.audio.previousRoute.rawValue)
                    row("Route reason", session.audio.routeChangeReason)
                    row("Media services", session.audio.mediaServicesState)
                    row("Audio session", session.audio.audioSessionState)
                    row("audio_availability_state", session.audio.interruption.state.rawValue)
                    row("interruption_started_at", format(session.audio.interruption.interruptionStartedAt))
                    row("interruption_ended_at", format(session.audio.interruption.interruptionEndedAt))
                    row("interruption_reason", session.audio.interruption.interruptionReason ?? "Unavailable")
                    row("mic_track_state", session.pttSnapshot.state == .transmitting ? "publishing" : "muted")
                    row("remote_audio_state", session.room.connectionState == .connected ? "connected" : "unavailable")
                    row("recovery_started_at", format(session.audio.interruption.recoveryStartedAt))
                    row("recovery_completed_at", format(session.audio.interruption.recoveryCompletedAt))
                    row("recovery_ms", latency(session.audio.interruption.recoveryMilliseconds))
                    row("auto_recovery_result", session.audio.interruption.autoRecoveryResult)
                    row("last_recovery_error", session.audio.interruption.lastRecoveryError ?? "None")
                    row("post_call_rearm", session.postCallRearmState.rawValue)
                    row("RTT", "Unavailable")
                    row("Jitter", "Unavailable")
                    row("Packet loss", "Unavailable")
                }
                Section("Apple PushToTalk") {
                    row("Framework", session.pushToTalk.state.rawValue)
                    row("PT channel UUID", session.pushToTalk.channelUUID?.uuidString ?? "Unavailable")
                    row("Ephemeral token", session.pushToTalk.tokenRegistrationState)
                    row("System channel restored", session.pushToTalk.systemChannelRestored ? "Yes" : "No")
                    row("Restore state", session.pttRestoreState)
                    row("Restore started", format(session.pttRestoreStartedAt))
                    row("Restore completed", format(session.pttRestoreCompletedAt))
                    row("Restore duration", latency(session.pttRestoreMilliseconds))
                    row("RX path", session.rxPath)
                    row("Last incoming push", format(session.pushToTalk.lastIncomingPushAt))
                    row("Last incoming lease", session.pushToTalk.lastIncomingPushLeaseId ?? "Unavailable")
                    row("Last transmit source", session.pushToTalk.lastTransmitRequestSource)
                    row("Accessory events", session.pushToTalk.accessoryButtonEventsEnabled ? "Enabled" : "Disabled")
                    row("Headset PTT setting", session.pushToTalk.headsetPttEnabled ? "ON" : "OFF")
                    row("Handsfree begin/end", "\(session.pushToTalk.handsfreeBeginCount) / \(session.pushToTalk.handsfreeEndCount)")
                    row("Last handsfree begin", format(session.pushToTalk.lastHandsfreeBeginAt))
                    row("Last handsfree end", format(session.pushToTalk.lastHandsfreeEndAt))
                    row("Generic MFB", session.pushToTalk.genericMfbSupportState)
                    row("Background cleanup", session.backgroundTaskState)
                    row("APNs PTT", "Server credential presence required")
                }
                if let error = session.pttSnapshot.lastError ?? session.room.lastError ?? session.audio.lastError ?? session.lastError {
                    Section("Last error") { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    private func format(_ date: Date?) -> String {
        date?.formatted(.iso8601) ?? "Unavailable"
    }

    private func latency(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "Unavailable"
    }
}

private struct SystemVolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
