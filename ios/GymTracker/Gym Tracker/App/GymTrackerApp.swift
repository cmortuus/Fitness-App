import SwiftUI

@main
struct GymTrackerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.themePreference) private var themePreference: String = "dark"
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
                        .onChange(of: scenePhase) { _, newPhase in
                            guard newPhase == .active else { return }
                            Task { await WorkoutSyncService.shared.syncRecentWorkouts() }
                        }
                } else {
                    LoginView()
                }
            }
            .environment(auth)
            .preferredColorScheme(themePreference == "light" ? .light : .dark)
        }
    }
}
