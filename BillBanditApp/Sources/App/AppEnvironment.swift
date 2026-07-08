import Foundation
import SwiftUI

@MainActor
@Observable
final class RootViewModel {
    enum Phase {
        case launching
        case welcome
        case signIn
        case main
    }

    var container: DataContainer
    var phase: Phase
    var currentUser: UserProfile?

    init(container: DataContainer, startsAuthenticated: Bool = false) {
        self.container = container
        self.phase = startsAuthenticated ? .main : .launching
    }

    func bootstrap() async {
        guard phase == .launching else { return }
        do {
            currentUser = try await container.authRepository.me()
            phase = .main
        } catch {
            phase = .welcome
        }
    }

    func showSignIn() {
        phase = .signIn
    }

    func finishAuthentication(_ user: UserProfile) {
        currentUser = user
        phase = .main
    }

    func useDevSession() {
        #if DEBUG
        container = AppDependencies.mock()
        Task {
            do {
                currentUser = try await container.authRepository.me()
                phase = .main
            } catch {
                currentUser = nil
                phase = .signIn
            }
        }
        #endif
    }

    func signOut() async {
        try? await KeychainTokenStore().clearToken()
        await container.sessionState.clear()
        currentUser = nil
        container = AppDependencies.live()
        phase = .signIn
    }

    func handle(url: URL) {
        guard container.capabilities.inviteLinks else { return }
    }
}

private struct DataContainerKey: EnvironmentKey {
    static let defaultValue = AppDependencies.live()
}

extension EnvironmentValues {
    var dataContainer: DataContainer {
        get { self[DataContainerKey.self] }
        set { self[DataContainerKey.self] = newValue }
    }
}

enum MainTab: Hashable {
    case trips
    case friends
    case settings
}

struct MainTabView: View {
    let container: DataContainer
    let currentUser: UserProfile?
    let onSignOut: () async -> Void
    @State private var selection: MainTab = .trips

    var body: some View {
        TabView(selection: $selection) {
            TripsNavigationView(container: container)
                .tabItem {
                    Label("Trips", systemImage: "receipt")
                }
                .tag(MainTab.trips)

            FriendsView(model: FriendsViewModel(container: container))
                .tabItem {
                    Label("Friends", systemImage: "person.2")
                }
                .tag(MainTab.friends)

            SettingsView(
                model: SettingsViewModel(authRepository: container.authRepository, initialUser: currentUser),
                onSignOut: onSignOut
            )
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(MainTab.settings)
        }
        .tint(BBColor.accent)
    }
}
