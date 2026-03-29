import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NutritionView()
                .tabItem {
                    Label("Nutrition", systemImage: "fork.knife")
                }
                .tag(0)

            ActivityView()
                .tabItem {
                    Label("Activity", systemImage: "figure.run")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
        .tint(.blue)
    }
}
