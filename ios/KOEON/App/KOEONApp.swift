import SwiftUI

@main
struct KOEONApp: App {
    @StateObject private var intercomSession = IntercomSessionController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        Batv1CrashBreadcrumbStore.shared.startRun(build: "\(version) (\(build))")
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
                    if phase == .background {
                        Batv1CrashBreadcrumbStore.shared.markCleanExit()
                    } else if phase == .active {
                        Batv1CrashBreadcrumbStore.shared.record(role: "APP", stage: "APP_RESUME")
                    }
                    intercomSession.appLifecycleDidChange(lifecycleState)
                }
        }
    }

    private func handleInviteURL(_ url: URL) {
        guard let token = InviteDeepLinkRouter.route(url) else { return }
        Task { await intercomSession.enroll(inviteToken: token) }
    }
}
