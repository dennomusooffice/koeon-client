import SwiftUI
import AppIntents

@main
struct KOEONApp: App {
    @StateObject private var intercomSession = IntercomSessionController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        AudioLifecycleBreadcrumbStore.shared.startRun(build: "\(version) (\(build))")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(intercomSession)
                .onOpenURL(perform: handleInviteURL)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { handleInviteURL(url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    let lifecycleState = switch phase {
                    case .active: "active"
                    case .inactive: "inactive"
                    case .background: "background"
                    @unknown default: "unknown"
                    }
                    AudioLifecycleBreadcrumbStore.shared.recordAppLifecycle(lifecycleState)
                    intercomSession.appLifecycleDidChange(lifecycleState)
                }
        }
    }

    private func handleInviteURL(_ url: URL) {
        guard let token = InviteDeepLinkRouter.route(url) else { return }
        Task { await intercomSession.enroll(inviteToken: token) }
    }
}

/// System-recognized PTT intent; no foreground transition is requested.
struct ToggleKoeonTransmissionIntent: PushToTalkTransmissionIntent {
    static var title: LocalizedStringResource = "KOEON送信を切り替える"
    static var description = IntentDescription("接続済みのKOEONで送信開始・停止を切り替えます。アプリの設定で有効にしてください。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        switch await IntercomSessionController.shared.toggleActionButtonPttFromIntent() {
        // A success dialog blocks the next physical Action button invocation,
        // including the stop request while locked. Use the existing audio cues.
        case .startRequested, .stopRequested, .settling: return .result()
        case .disabled: throw ActionButtonPttError.disabled
        case .unavailable: throw ActionButtonPttError.unavailable
        }
    }
}

private enum ActionButtonPttError: LocalizedError {
    case disabled, unavailable

    var errorDescription: String? {
        switch self {
        case .disabled: "KOEONの設定でアクションボタンPTTを有効にしてください。"
        case .unavailable: "送信できません。KOEONを開き、接続と送信可能な状態を確認してください。"
        }
    }
}

/// A direct system shortcut also lets the Action button select the existing intent.
/// No user, channel, credential, or audio data is donated as a phrase parameter.
struct KoeonPttAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleKoeonTransmissionIntent(),
            phrases: ["\(.applicationName)で送信を切り替える", "Toggle transmission in \(.applicationName)"],
            shortTitle: "送信を切り替える",
            systemImageName: "mic"
        )
    }
}
