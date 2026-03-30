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
                            Task { await WorkoutSyncService.shared.syncRecentWorkouts() }
                        }
                } else {
                    LoginView()
                }
            }
            .environment(auth)
            .preferredColorScheme(.dark)
        }
    }
}
