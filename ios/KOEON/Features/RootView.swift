import SwiftUI
import MediaPlayer
import UIKit

struct RootView: View {
    @EnvironmentObject private var session: IntercomSessionController
    @AppStorage("consoleDarkMode") private var darkConsole = false
    @State private var showPowerConfirmation = false
    @State private var showMembers = false
    @State private var showChannels = false
    @State private var channelDigits: String?
    @State private var channelEntryRejected = false
    @State private var channelRejectionSequence = 0
    @State private var channelFlashRed = false
    @State private var channelDigitCount = 1
    @State private var pendingChannelID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var showQRScanner = false
    @State private var inviteInput = ""
    @State private var pttTouchEdgeGate = AppPttTouchEdgeGate()

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                consoleHeader
                if session.isPoweredOn || session.isJoined {
                    joinedView
                } else {
                    ScrollView {
                        selectionView
                        if let error = session.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(darkConsole ? Color(red: 0.11, green: 0.12, blue: 0.11) : Color(red: 0.96, green: 0.96, blue: 0.94))
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("接続を終了しますか？", isPresented: $showPowerConfirmation) {
                Button("POWER OFF · 接続終了", role: .destructive) { Task { await session.leave(powerOff: true) } }
            } message: { Text("送受信を終了します。利用登録は保持します。") }
            .sheet(isPresented: $showMembers) {
                NavigationStack {
                    List(Array(session.room.participantNames.enumerated()), id: \.offset) { _, name in Text(name).font(.title2) }
                    .navigationTitle("参加メンバー")
                    .toolbar { Button("閉じる") { showMembers = false } }
                }
            }
            .sheet(isPresented: $showChannels) {
                NavigationStack {
                    List {
                        Button("前のCH") {
                            if let current = session.joinedSession?.channel.id { switchRelative(-1, current: current) }
                            showChannels = false
                        }.disabled(!channelSelectionEnabled)
                        Button("次のCH") {
                            if let current = session.joinedSession?.channel.id { switchRelative(1, current: current) }
                            showChannels = false
                        }.disabled(!channelSelectionEnabled)
                        ForEach(ChannelSwitchPolicy.ordered(session.fixture?.channels ?? [])) { channel in
                            Button(channel.name) { stageChannel(channel.id); showChannels = false }
                                .disabled(!channelSelectionEnabled)
                        }
                        if session.channelChoicesRefreshFailed {
                            Button("CH一覧を再取得") { Task { await session.refreshChannelChoices() } }
                        }
                    }
                    .navigationTitle("チャネル一覧")
                    .toolbar { Button("閉じる") { showChannels = false } }
                }
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
            .task(id: session.operationalState) {
                if session.operationalState == .active { await session.refreshChannelChoices() }
            }
        }
        .tint(KOEONPalette.cyan)
        .preferredColorScheme(darkConsole ? .dark : .light)
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
            } else if session.fixture == nil {
                if session.isLoading {
                    ProgressView("接続を確認しています")
                } else {
                    Text("ユーザー情報を取得できませんでした。")
                    Button("再試行") { Task { await session.loadFixture() } }
                        .buttonStyle(.borderedProminent)
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
            Text("再生ボタンPTTは試験中です。Bluetooth接続後にONにしてください。アプリ再起動・Bluetooth再接続後はOFF→ONが必要です。有効中は音楽の再生操作がPTTに切り替わります。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("この端末のユーザーを変更") {
                Task { await session.resetDeviceAssignment() }
            }
            .buttonStyle(.bordered)
            .disabled(session.isLoading)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(KOEONPalette.cyan.opacity(0.35)))
    }

    private var joinedView: some View {
        VStack(spacing: 8) {
            statusCard
            statusLamps
            channelKeys
            if session.needsRuntimeRecovery {
                Button("接続を再試行") { session.retryRuntimeRecovery() }
                    .disabled(session.isRestoringRuntime || session.isLoading)
            }
            if session.audio.interruption.state == .recoveryFailed {
                Button("音声を再接続") { session.retryAudioRecovery() }
            }
            GeometryReader { geometry in
                pttButton(diameter: min(220, geometry.size.height, geometry.size.width))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var currentChannelNumber: Int? {
        if let channel = session.fixture?.channels.first(where: { $0.id == session.joinedSession?.channel.id }) {
            return ChannelSwitchPolicy.number(channel.channelNumber)
        }
        return ChannelSwitchPolicy.number(session.joinedSession?.channel.channelNumber)
    }
    private var keyDigits: (ones: Int?, tens: Int?) {
        ChannelSwitchPolicy.digits(number: currentChannelNumber, entry: channelDigits, count: channelDigitCount)
    }
    private var twoDigitActive: Bool { channelDigits != nil ? channelDigitCount == 2 : (currentChannelNumber ?? 0) >= 10 }
    private var channelKeys: some View {
        VStack(spacing: 5) {
            HStack {
                Text("CHANNEL SELECT").font(.caption.monospaced())
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("TENS")
                    Circle().fill(Color.blue).frame(width: 6, height: 6).padding(.leading, 5)
                    Text("ONES")
                }.font(.system(size: 9, weight: .semibold, design: .monospaced))
                .accessibilityElement(children: .ignore).accessibilityLabel("10の位：緑、1の位：青")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 5) {
                ForEach(0..<10) { number in
                    Button {
                        resetChannelRejection()
                        pendingChannelID = nil
                        if channelDigits != nil && channelDigitCount == 2 {
                            if (channelDigits?.count ?? 0) < 2 { channelDigits?.append(String(number)) }
                        } else { channelDigitCount = 1; channelDigits = String(number) }
                    } label: {
                        Text("\(number)").font(.title3.monospaced().bold())
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(!channelSelectionEnabled)
                    .overlay(ChannelKeyLED(blue: keyDigits.ones == number, green: keyDigits.tens == number, red: channelFlashRed))
                    .accessibilityLabel("CH \(number)")
                    .accessibilityValue(keyDigits.ones == number && keyDigits.tens == number ? "1の位・10の位" : keyDigits.ones == number ? "1の位" : keyDigits.tens == number ? "10の位" : "消灯")
                }
            }
            HStack {
                Button("2桁") { resetChannelRejection(); pendingChannelID = nil; channelDigitCount = 2; channelDigits = "" }.disabled(!channelSelectionEnabled)
                    .overlay(ChannelKeyLED(blue: false, green: twoDigitActive))
                Button("確定") {
                    guard channelSelectionEnabled else { return }
                    if let target = candidateChannel {
                        Task { await session.switchChannel(to: target.id) }
                        cancelChannelEntry()
                    } else {
                        channelEntryRejected = true
                        channelRejectionSequence += 1
                        UIAccessibility.post(notification: .announcement, argument: "未割り当てのCHです")
                    }
                }.disabled(!ChannelSwitchPolicy.canConfirm(entry: channelDigits, count: channelDigitCount, named: pendingChannelID != nil && candidateChannel != nil) || !channelSelectionEnabled)
                Button("取消") { cancelChannelEntry() }.disabled(channelDigits == nil)
            }.frame(minHeight: 44)

        }
        .buttonStyle(ConsoleKeyStyle())
        .task(id: "\(channelDigits ?? "-")/\(pendingChannelID ?? "-")/\(channelRejectionSequence)") {
            guard channelDigits != nil else { return }
            do { try await Task.sleep(for: .seconds(5)); cancelChannelEntry() } catch { }
        }
        .task(id: channelRejectionSequence) {
            guard channelRejectionSequence > 0 else { return }
            do {
                if reduceMotion {
                    channelFlashRed = true
                    try await Task.sleep(for: .milliseconds(1200))
                    channelFlashRed = false
                } else {
                    for _ in 0..<3 {
                        channelFlashRed = true
                        try await Task.sleep(for: .milliseconds(200))
                        channelFlashRed = false
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
            } catch { }
        }
        .onChange(of: session.joinedSession?.channel.id) { _, _ in cancelChannelEntry() }
    }
    private var channelSelectionEnabled: Bool { session.operationalState == .active && session.pttSnapshot.state == .idle && !session.hapticSnapshot.inputPressed }
    private func numberedChannel(_ number: Int) -> Channel? {
        ChannelSwitchPolicy.numbered(session.fixture?.channels ?? [], number: number)
    }
    private var consoleHeader: some View {
        ZStack {
            VStack(spacing: 1) {
                ConsoleEmblem().frame(width: 34, height: 30)
                Text("KOEON").font(.system(size: 10, weight: .bold)).tracking(2).lineLimit(1)
            }.frame(maxWidth: .infinity).padding(.horizontal, 108)
            HStack {
            Button { showPowerConfirmation = true } label: {
                Image(systemName: "power").frame(width: 44, height: 44)
            }
            .accessibilityLabel("POWER")
            .disabled(!session.isPoweredOn && !session.isJoined)
            Spacer()
            Button { showSettings = true } label: {
                VStack { Image(systemName: "slider.horizontal.3"); Text("SETTINGS").font(.system(size: 8)) }.frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Settings")
            Button { showDiagnostics = true } label: {
                VStack { Image(systemName: "waveform.path.ecg"); Text("DIAG").font(.system(size: 8)) }.frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Diagnostics")
        }
        }
        .buttonStyle(ConsoleKeyStyle())
        .disabled(session.hapticSnapshot.inputPressed)
    }

    private var warningActive: Bool {
        session.audio.interruption.state != .ready || session.lastError != nil || session.pttSemanticState == .error
    }
    private var lampColor: Color {
        if warningActive { return .red }
        switch session.pttSemanticState {
        case .talking: return .green
        case .busyRemote, .preparing, .recovering: return .orange
        default: return darkConsole ? Color(white: 0.26) : Color(white: 0.72)
        }
    }
    private var consoleStatus: String {
        warningActive ? "PAUSED · 要確認" : session.pttSemanticState.rawValue.replacingOccurrences(of: "_", with: " ")
    }
    private var candidateChannel: Channel? {
        if let id = pendingChannelID { return session.fixture?.channels.first { $0.id == id } }
        guard let digits = channelDigits, digits.count == channelDigitCount, let number = Int(digits) else { return nil }
        return numberedChannel(number)
    }
    private func stageChannel(_ id: String) {
        guard channelSelectionEnabled, let channel = session.fixture?.channels.first(where: { $0.id == id }) else { return }
        resetChannelRejection()
        pendingChannelID = id
        channelDigits = ChannelSwitchPolicy.number(channel.channelNumber).map(String.init) ?? ""
        channelDigitCount = max(1, channelDigits?.count ?? 1)
    }
    private func resetChannelRejection() { channelEntryRejected = false; channelRejectionSequence = 0; channelFlashRed = false }
    private func cancelChannelEntry() { resetChannelRejection(); channelDigits = nil; pendingChannelID = nil }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let digits = channelDigits {
                Text("CHANNEL CHANGE / CH変更").font(.caption.monospaced().bold())
                Text("FROM / 現在").font(.caption2)
                Text(session.joinedSession?.channel.name ?? "—").font(.title2.monospaced().bold()).lineLimit(1)
                Text("TO / 変更先").font(.caption2)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    HStack(spacing: 5) {
                        Text("CH").font(.title2.monospaced())
                        ForEach(0..<channelDigitCount, id: \.self) { index in
                            let characters = Array(digits)
                            let cursor = pendingChannelID == nil && index == characters.count
                            VStack(spacing: 1) {
                                Text(index < characters.count ? String(characters[index]) : "_").font(.system(size: 28, weight: .bold, design: .monospaced))
                                Rectangle().frame(width: 22, height: 2).opacity(cursor && (reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0) ? 1 : 0)
                            }
                        }
                        Spacer()
                        Text(channelEntryRejected ? "未割当" : digits.count < channelDigitCount && pendingChannelID == nil ? "入力中" : "確定待ち").font(.callout.bold())
                    }
                }
                Text(channelEntryRejected ? "このCHは未割り当てです" : candidateChannel?.name ?? "番号を選択して確定してください").font(.title3).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                HStack {
                    Text("\(currentChannelNumber.map { "CH\($0)" } ?? "CH —") / \(session.room.connectionState.rawValue)").font(.caption2)
                    Spacer()
                    Text(consoleStatus).font(.caption2.bold())
                }.lineLimit(1)
                Button { showChannels = true } label: {
                    Text(session.joinedSession?.channel.name ?? "—").font(.title2.monospaced().bold()).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(!channelSelectionEnabled)
                Text("SPEAKER / 発話者").font(.caption2)
                Text(session.pttSemanticState == .talking ? "自分" : session.room.currentSpeaker ?? "—").font(.title2).lineLimit(1)
                Text("MEMBERS / 参加者 \(session.room.participantNames.count)").font(.caption2)
                Button { if !session.hapticSnapshot.inputPressed { showMembers = true } } label: {
                    Text(session.room.participantNames.isEmpty ? "—" : session.room.participantNames.joined(separator: " · "))
                        .font(.title2).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider().overlay(Color.brown.opacity(0.4))
            HStack(alignment: .bottom) {
                Text("AUDIO: \(session.audio.route.rawValue)").lineLimit(1)
                Spacer(minLength: 4)
                Text(ConsoleVersion.label).lineLimit(1)
            }.font(.caption2)
            if warningActive { Text(session.lastError ?? "音声中断 · 詳細はDiagnostics").font(.caption2).lineLimit(1) }
        }
        .foregroundStyle(Color(red: 0.18, green: 0.12, blue: 0.03))
        .tint(Color(red: 0.18, green: 0.12, blue: 0.03))
        .padding(12)
        .frame(height: 218)
        .background((darkConsole ? Color(red: 0.76, green: 0.55, blue: 0.24) : Color(red: 0.94, green: 0.75, blue: 0.40)).gradient, in: RoundedRectangle(cornerRadius: 6))
        .padding(5)
        .background(darkConsole ? Color(white: 0.10) : Color(white: 0.69), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusLamps: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                ConsoleLamp(label: "PTT", color: lampColor)
                ConsoleLamp(label: "RX", color: ([.active, .endPending, .draining].contains(session.rxSnapshot.state) || (session.rxSnapshot.state != .idle && session.room.receiveLevelDbfs != nil)) ? .blue : .gray.opacity(0.5))
            }
            VStack {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    VStack {
                        ConsoleMeter(label: "TX IN", db: session.pttSemanticState == .talking ? session.inputGain.currentLevelDbfs() : nil, color: .green)
                        ConsoleMeter(label: "RX", db: session.room.receiveLevelDbfs, color: .blue)
                    }
                }
            }
        }.padding(.vertical, 2)
    }

    private func pttButton(diameter: CGFloat) -> some View {
        let rxOnly = session.joinedSession?.canPublish != true
        let inputPressed = session.hapticSnapshot.inputPressed
        let semantic = session.pttSemanticState
        let fill = lampColor
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
            Circle().fill(ConsoleKeySurface.face(dark: darkConsole))
            Circle().fill(RadialGradient(stops: [.init(color: .clear, location: 0.7), .init(color: fill.opacity(0.12), location: 0.88), .init(color: fill.opacity(0.48), location: 1)], center: .center, startRadius: 0, endRadius: diameter / 2))
            Circle().strokeBorder(fill.opacity(0.8), lineWidth: 5)
            Circle().strokeBorder(ConsoleKeySurface.rim, lineWidth: 1)
            VStack(spacing: 8) {
                Text("PTT").font(.system(size: 42, weight: .bold)).tracking(3)
                Image(systemName: icon).font(.title3)
                Text(consoleStatus)
                    .font(.title3.bold())
            }
            .foregroundStyle(darkConsole ? Color(white: 0.90) : Color(white: 0.20))
        }
        .frame(width: diameter, height: diameter)
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
        .onDisappear { if pttTouchEdgeGate.ended() { session.pttUp() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rxOnly ? "Receive only" : "Push to talk")
        .accessibilityValue(semantic.rawValue)
        .accessibilityHint(rxOnly ? "This user cannot publish audio" : "Hold to transmit, release to stop")
        .allowsHitTesting(!rxOnly && session.canPressPTT && channelDigits == nil)
    }

    private func switchRelative(_ direction: Int, current: String) {
        guard let target = ChannelSwitchPolicy.adjacent(session.fixture?.channels ?? [], currentId: current, direction: direction) else { return }
        stageChannel(target)
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
    @State private var resetConfirmation = false
    @AppStorage("consoleDarkMode") private var darkConsole = false
    @EnvironmentObject private var session: IntercomSessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("外観") {
                    Picker("本体モード", selection: $darkConsole) {
                        Text("ライト · ホワイト").tag(false)
                        Text("ダーク · ブラック").tag(true)
                    }.pickerStyle(.segmented)
                    Text(ConsoleVersion.label).font(.caption)
                    Text("メーターは音声の強さを表示します。端末の音量設定とは別です。「—」は計測なし。").font(.caption)
                }
                Section("ヘッドセットPTT") {
                    Toggle("Headset PTT Button", isOn: Binding(get: { session.pushToTalk.headsetPttEnabled }, set: { session.setHeadsetPttEnabled($0) }))
                    Text("再生ボタンPTTは試験中です。Bluetooth再接続・アプリ再起動後はOFF→ONが必要です。有効中は音楽の再生操作がPTTに切り替わります。")
                }
                Section("出力音量") { SystemVolumeControl().frame(height: 34) }
                Section("アカウント") {
                    Button("この端末のユーザーを変更", role: .destructive) { resetConfirmation = true }
                        .disabled(session.isLoading || session.pttSnapshot.state != .idle)
                }
                Section("アクションボタンPTT（試作）") {
                    Toggle("ショートカットから送信を切り替える", isOn: Binding(
                        get: { session.actionButtonPttEnabled },
                        set: { session.setActionButtonPttEnabled($0) }
                    ))
                    Text("「ショートカット」で「KOEON送信を切り替える」アクションを含むショートカットを作成し、iPhoneのアクションボタンに割り当てます。KOEONで接続後に使えます。長押しで開始、もう一度長押しで停止します。ロック中も操作できる設定です。実機での動作は検証中です。送信は最大60秒です。")
                        .font(.footnote)
                }
                InputGainSettings()
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
                    row("現在の接続設定", session.appliedAudioPublishProfile?.displayName ?? "未接続")
                    Text("LiveKitの送信音質と通信量を変更します。速度制限中は低音質（12kbps）を選んでください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if session.isJoined {
                        Text("選択値は保存され、次回接続時に適用されます。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .confirmationDialog("この端末のユーザーを変更しますか？", isPresented: $resetConfirmation) {
                Button("変更", role: .destructive) { Task { await session.resetDeviceAssignment(); dismiss() } }
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
    static let cyan = Color(red: 0.12, green: 0.42, blue: 0.68)
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
                    Button("Export 24-hour Field Journal") { session.exportFieldJournal() }
                        .disabled(session.fieldJournalExporting)
                    if let url = session.fieldJournalURL { ShareLink("Share Field Journal", item: url) }
                    if !session.fieldJournalStatus.isEmpty { Text(session.fieldJournalStatus) }
                }
                InputGainSettings()
                Section("Session") {
                    row("Connection", session.room.connectionState.rawValue)
                    row("Room", session.joinedSession?.roomName ?? "—")
                    row("User", session.joinedSession?.user.name ?? session.selectedUser?.name ?? "—")
                    row("Channel", session.joinedSession?.channel.name ?? session.selectedChannel?.name ?? "—")
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
                    row("PTT block reason", session.pttBlockReason)
                    row("Apple TX failure operation", session.appleLastTransmitFailureOperation ?? "None")
                    row("Apple TX failure code", session.appleLastTransmitFailureCode ?? "None")
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
                    row("remote_media_speaker_active", session.rxConsistencySnapshot.remoteMediaSpeakerActive ? "Yes" : "No")
                    row("validated_remote_rx_active", session.rxConsistencySnapshot.validatedRemoteRxActive ? "Yes" : "No")
                    row("remote_pcm_observed", session.rxConsistencySnapshot.remotePcmObserved ? "Yes" : "No")
                    row("remote_track_subscribed", session.rxConsistencySnapshot.trackSubscribed ? "Yes" : "No")
                    row("rx_divergence_watchdog_ms", "\(rxDivergenceWatchdogMilliseconds)")
                    row("rx_divergence_last_event", session.rxDivergenceDiagnostics.last?.event ?? "None")
                    row("rx_divergence_recovery_attempts", "\(session.rxConsistencySnapshot.recoveryAttempts)")
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

private struct InputGainSettings: View {
    @EnvironmentObject private var session: IntercomSessionController
    var body: some View {
                Section("マイクゲイン") {
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
                        in: -6...24,
                        step: 1
                    )
                    row("Route / effective", "\(gain.route) / \(String(format: "%.1f", gain.effectiveGainDb)) dB")
                    row("RMS / Peak", "\(gain.rmsDbfs.map { String(format: "%.1f", $0) } ?? "Unavailable") / \(gain.peakDbfs.map { String(format: "%.1f", $0) } ?? "Unavailable")")
                    row("Limiter hits", "\(gain.limiterHits)")
                    Button("Calibrate 3 seconds") { session.startInputGainCalibration() }
                    Button("Reset route profile", role: .destructive) { session.resetInputGainProfile() }
                    Text("TASK003G6B_AUDIO_ROUTE_SELECTION").font(.caption2).foregroundStyle(.secondary)
                }

    }
    private func row(_ label: String, _ value: String) -> some View { LabeledContent(label, value: value) }
}

private enum ConsoleVersion {
    static var label: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "v\(version) (\(build))"
    }
}

private struct ConsoleKeyStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(scheme == .dark ? Color(white: 0.9) : Color(white: 0.2))
            .padding(.horizontal, 4)
            .background(ConsoleKeySurface.face(dark: scheme == .dark), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ConsoleKeySurface.rim, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 2, y: configuration.isPressed ? 0 : 3)
            .offset(y: configuration.isPressed ? 2 : 0)
    }
}

private enum ConsoleKeySurface {
    static func face(dark: Bool) -> LinearGradient {
        LinearGradient(colors: dark
            ? [Color(red: 0.45, green: 0.47, blue: 0.46).opacity(0.67), Color(white: 0.20).opacity(0.73), Color(white: 0.15).opacity(0.8)]
            : [.white.opacity(0.94), Color(red: 0.80, green: 0.82, blue: 0.81).opacity(0.67), Color(white: 0.88).opacity(0.87)], startPoint: .top, endPoint: .bottom)
    }
    static var rim: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.08), .black.opacity(0.22)], startPoint: .top, endPoint: .bottom)
    }
}

private struct ConsoleLamp: View {
    let label: String
    let color: Color
    var body: some View {
        HStack { Circle().fill(color).frame(width: 12, height: 12); Text(label).font(.caption.monospaced().bold()) }
            .accessibilityElement(children: .combine)
    }
}

private struct ConsoleMeter: View {
    let label: String
    let db: Float?
    let color: Color
    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10, design: .monospaced)).frame(width: 35, alignment: .leading)
            ForEach(0..<12) { index in
                Rectangle().fill(db.map { $0.isFinite && Float(index) < max(0, min(12, ($0 + 60) / 5)) } == true ? (index >= 11 ? Color.red : color) : Color.gray.opacity(0.25)).frame(height: 8)
            }
            Text(db.map { $0.isFinite ? String(format: "%.0f", $0) : "—" } ?? "—").font(.caption2.monospaced()).frame(width: 25)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(label): \(db.map { String(format: "%.0f dBFS", $0) } ?? "未取得")")
    }
}

private struct ChannelKeyLED: View {
    let blue: Bool
    let green: Bool
    var red: Bool = false
    var body: some View {
        let light = LinearGradient(stops: [
                .init(color: red ? .red : green ? .green : blue ? .blue : .clear, location: 0),
                .init(color: red ? .red : green ? .green : blue ? .blue : .clear, location: 0.499),
                .init(color: red ? .red : blue ? .blue : green ? .green : .clear, location: 0.5),
                .init(color: red ? .red : blue ? .blue : green ? .green : .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        ZStack {
            RoundedRectangle(cornerRadius: 7).strokeBorder(light.opacity(0.08), lineWidth: 16).blur(radius: 3)
            RoundedRectangle(cornerRadius: 7).strokeBorder(light.opacity(0.12), lineWidth: 9).blur(radius: 2)
            RoundedRectangle(cornerRadius: 7).strokeBorder(light.opacity(0.22), lineWidth: 5).blur(radius: 1)
            RoundedRectangle(cornerRadius: 7).strokeBorder(light.opacity(0.8), lineWidth: 1.5)
            RoundedRectangle(cornerRadius: 7).strokeBorder(ConsoleKeySurface.rim, lineWidth: 0.7)
        }.clipShape(RoundedRectangle(cornerRadius: 7)).allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ConsoleEmblem: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(stops: [
                    .init(color: Color(red: 1, green: 0.945, blue: 0.722), location: 0),
                    .init(color: Color(red: 0.706, green: 0.518, blue: 0.188), location: 0.35),
                    .init(color: Color(red: 1, green: 0.902, blue: 0.627), location: 0.46),
                    .init(color: Color(red: 0.72, green: 0.52, blue: 0.19), location: 0.52),
                    .init(color: Color(red: 0.851, green: 0.714, blue: 0.361), location: 0.82),
                    .init(color: Color(red: 1, green: 0.941, blue: 0.667), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(red: 0.56, green: 0.38, blue: 0.11), lineWidth: 0.7))
            Image("ConsoleEmblem").resizable().frame(width: 42, height: 42)
                .foregroundStyle(Color(red: 1, green: 0.95, blue: 0.73)).offset(x: -1.1, y: 0.7)
            Image("ConsoleEmblem").resizable().frame(width: 42, height: 42)
                .foregroundStyle(Color(red: 0.35, green: 0.23, blue: 0.07)).offset(x: -1.1)
        }
        .shadow(color: .black.opacity(0.3), radius: 0.6, x: 0, y: 1)
        .accessibilityHidden(true)
    }
}
