import SwiftUI

@main
struct KOEONApp: App {
    @StateObject private var intercomSession = IntercomSessionController()
    @Environment(\.scenePhase) private var scenePhase

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
                    intercomSession.appLifecycleDidChange(lifecycleState)
                }
        }
    }

    private func handleInviteURL(_ url: URL) {
        guard let token = InviteDeepLinkRouter.route(url) else { return }
        Task { await intercomSession.enroll(inviteToken: token) }
    }
}
