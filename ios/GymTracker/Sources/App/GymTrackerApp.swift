import SwiftUI

@main
struct GymTrackerApp: App {
    @StateObject private var auth = AuthService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthenticated {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(auth)
            .preferredColorScheme(.dark)
        }
    }
}
