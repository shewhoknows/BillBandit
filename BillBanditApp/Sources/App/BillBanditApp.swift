import SwiftUI

@main
struct BillBanditApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Temporary root while the app shell is under construction.
struct RootView: View {
    var body: some View {
        ZStack {
            Color(red: 15 / 255, green: 69 / 255, blue: 214 / 255)
                .ignoresSafeArea()
            Text("BillBandit")
                .font(.system(.largeTitle, design: .serif).weight(.black))
                .foregroundStyle(Color(red: 1, green: 245 / 255, blue: 222 / 255))
        }
    }
}

#Preview {
    RootView()
}
