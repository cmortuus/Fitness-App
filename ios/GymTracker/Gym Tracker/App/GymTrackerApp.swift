import SwiftUI

@main
struct GymTrackerApp: App {
    @State private var auth = AuthService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthenticated {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
            .environment(auth)
            .preferredColorScheme(.dark)
        }
    }
}
