import SwiftUI

@main
struct BillBanditApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(model: RootViewModel(container: AppDependencies.live()))
        }
    }
}

struct RootView: View {
    @State var model: RootViewModel

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                LaunchView(mode: .checking) {
                    model.showSignIn()
                }
            case .welcome:
                LaunchView(mode: .welcome) {
                    model.showSignIn()
                }
            case .signIn:
                SignInView(
                    model: SignInViewModel(authRepository: model.container.authRepository),
                    onAuthenticated: { user in
                        model.finishAuthentication(user)
                    },
                    onUseDevSession: {
                        model.useDevSession()
                    }
                )
            case .main:
                MainTabView(
                    container: model.container,
                    currentUser: model.currentUser,
                    onSignOut: {
                        await model.signOut()
                    }
                )
            }
        }
        .preferredColorScheme(.light)
        .environment(\.dataContainer, model.container)
        .task {
            await model.bootstrap()
        }
        .onOpenURL { url in
            model.handle(url: url)
        }
    }
}

#Preview {
    #if DEBUG
    RootView(model: RootViewModel(container: AppDependencies.mock(), startsAuthenticated: true))
    #else
    RootView(model: RootViewModel(container: AppDependencies.live()))
    #endif
}
