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
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch IntercomSessionController.shared.toggleActionButtonPtt() {
        case .startRequested: return .result(dialog: "送信開始を要求しました。開始音を待って話してください。")
        case .stopRequested: return .result(dialog: "送信を停止します。")
        case .settling: return .result(dialog: "送信の終了処理中です。少し待って再操作してください。")
        case .disabled: return .result(dialog: "KOEONの設定でアクションボタンPTTを有効にしてください。")
        case .unavailable: return .result(dialog: "送信できません。KOEONを開き、接続と送信可能な状態を確認してください。")
        }
    }
}
