import SwiftUI

@main
struct BillBanditApp: App {
    @UIApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var cloudShareDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// Nav-bar branding: Fredoka titles in cream over the cobalt background.
    init() {
        Money.setCurrentCurrency(.inr)
        LegacyReminderCleanup.retire()
        let cream = UIColor(Color.Brand.creamSoft)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [
            .foregroundColor: cream,
            .font: UIFont(name: "Fredoka-Bold", size: 34 * BrandFont.scale)!,
        ]
        appearance.titleTextAttributes = [
            .foregroundColor: cream,
            .font: UIFont(name: "Fredoka-SemiBold", size: 17 * BrandFont.scale)!,
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .preferredColorScheme(.light) // v1 is light-only (approved 2026-07-18)
                .task {
                    await CloudCollaborationService.shared.prepare()
                    if scenePhase == .active {
                        CloudCollaborationService.shared.startForegroundSync()
                    }
                }
                .onOpenURL { FriendInvitationService.shared.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        CloudCollaborationService.shared.startForegroundSync()
                        Task {
                            await CloudCollaborationService.shared.synchronize(
                                promoteLocalChanges: true
                            )
                            await FriendInvitationService.shared.refreshAcceptedInvites()
                        }
                    } else {
                        CloudCollaborationService.shared.stopForegroundSync()
                    }
                }
        }
        .modelContainer(AppStore.container)
    }
}
