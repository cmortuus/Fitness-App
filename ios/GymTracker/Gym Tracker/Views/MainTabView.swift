import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var showNutritionGoalsSheet = false

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView {
                selectedTab = 1
                showNutritionGoalsSheet = true
            }
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

            NutritionView(externalShowGoalsSheet: $showNutritionGoalsSheet)
                .tabItem {
                    Label("Log", systemImage: "plus.circle.fill")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
        .tint(Color(red: 0.004, green: 0.439, blue: 0.725)) // MacroFactor blue
    }
}
