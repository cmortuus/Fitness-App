import SwiftUI

@main
struct GymTrackerApp: App {
    @State private var auth = AuthService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthenticated {
                    MainTabView()
                        .task {
                            // Fire-and-forget — don't block app launch
                            Task { await SettingsSync.loadFromDB() }
                            Task { await HealthKitManager.shared.syncBodyWeightOnLaunch() }
                        }
                } else {
                    LoginView()
                        .task {
                            // AUTO-LOGIN FOR UI TESTING — REMOVE BEFORE SHIPPING
                            #if DEBUG
                            try? await auth.login(username: "claude_test", password: "TestPass123")
                            #endif
                        }
                }
            }
            .environment(auth)
            .preferredColorScheme(.dark)
        }
    }
}
