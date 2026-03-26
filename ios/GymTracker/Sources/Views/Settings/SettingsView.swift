import SwiftUI
import HealthKit

struct SettingsView: View {
    @EnvironmentObject var auth: AuthService
    @State private var weightUnit = "lbs"
    @State private var healthKitAuthorized = false
    @State private var healthStore = HKHealthStore()

    var body: some View {
        NavigationStack {
            List {
                // Profile
                Section("Profile") {
                    Text(auth.currentUser?.username ?? "User")
                }

                // Weight unit
                Section("Units") {
                    Picker("Weight", selection: $weightUnit) {
                        Text("lbs").tag("lbs")
                        Text("kg").tag("kg")
                    }
                    .pickerStyle(.segmented)
                }

                // Apple Health
                if HKHealthStore.isHealthDataAvailable() {
                    Section("Apple Health") {
                        if healthKitAuthorized {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Connect Apple Health") {
                                requestHealthKitPermissions()
                            }
                        }
                    }
                }

                // Account
                Section {
                    Button("Sign Out", role: .destructive) {
                        auth.logout()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func requestHealthKitPermissions() {
        let typesToWrite: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .bodyMass)!,
            HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!,
        ]

        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .bodyMass)!,
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
        ]

        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { success, error in
            DispatchQueue.main.async {
                healthKitAuthorized = success
                if let error {
                    print("HealthKit auth error: \(error)")
                }
            }
        }
    }
}
