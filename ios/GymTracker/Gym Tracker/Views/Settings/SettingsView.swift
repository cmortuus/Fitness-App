import SwiftUI
import HealthKit

struct SettingsView: View {
    @Environment(AuthService.self) var auth
    @State private var weightUnit = "lbs"
    @State private var healthKitAuthorized = false
    @State private var healthStore = HKHealthStore()

    // Profile
    @State private var age: Int?
    @State private var sex = "male"
    @State private var heightInches: Int?

    // Rest timers
    @State private var upperCompound = 180
    @State private var upperIsolation = 90
    @State private var lowerCompound = 240
    @State private var lowerIsolation = 120

    // Equipment weights (lbs)
    @State private var barbellWeight = 45.0
    @State private var smithWeight = 35.0
    @State private var ezBarWeight = 25.0
    @State private var ssbWeight = 65.0
    @State private var trapBarWeight = 55.0
    @State private var legPressWeight = 0.0
    @State private var hackSquatWeight = 0.0
    @State private var tBarWeight = 0.0

    // Body weight
    @State private var weighIns: [BodyWeightEntry] = []
    @State private var newWeight: Double?
    @State private var newBodyFat: Double?
    @State private var showWeighIn = false

    // Deload
    @State private var deloadWeightPct = 70
    @State private var deloadVolumePct = 60

    var body: some View {
        NavigationStack {
            List {
                // Profile
                Section("Profile") {
                    HStack {
                        Text("Username")
                        Spacer()
                        Text(auth.currentUser?.username ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Sex", selection: $sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                    }
                    HStack {
                        Text("Age")
                        Spacer()
                        TextField("Age", value: $age, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                }

                // Units
                Section("Units") {
                    Picker("Weight Unit", selection: $weightUnit) {
                        Text("lbs").tag("lbs")
                        Text("kg").tag("kg")
                    }
                    .pickerStyle(.segmented)
                }

                // Body Weight
                Section("Body Weight") {
                    if weighIns.isEmpty {
                        Text("No weigh-ins yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(weighIns.prefix(5)) { entry in
                            HStack {
                                Text(formatDate(entry.recorded_at))
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.1f %@",
                                    weightUnit == "lbs" ? entry.weight_kg * 2.20462 : entry.weight_kg,
                                    weightUnit))
                                    .font(.subheadline.bold())
                                if let bf = entry.body_fat_pct {
                                    Text(String(format: "%.1f%%", bf))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Button("Log Weigh-In") { showWeighIn = true }
                }

                // Rest Timers
                Section("Rest Timers") {
                    Stepper("Upper Compound: \(upperCompound/60)m \(upperCompound%60)s",
                            value: $upperCompound, in: 30...600, step: 15)
                    Stepper("Upper Isolation: \(upperIsolation/60)m \(upperIsolation%60)s",
                            value: $upperIsolation, in: 30...600, step: 15)
                    Stepper("Lower Compound: \(lowerCompound/60)m \(lowerCompound%60)s",
                            value: $lowerCompound, in: 30...600, step: 15)
                    Stepper("Lower Isolation: \(lowerIsolation/60)m \(lowerIsolation%60)s",
                            value: $lowerIsolation, in: 30...600, step: 15)
                }

                // Equipment Weights
                Section("Equipment Weights (\(weightUnit))") {
                    equipmentRow("Barbell", value: $barbellWeight)
                    equipmentRow("Smith Machine", value: $smithWeight)
                    equipmentRow("EZ Bar", value: $ezBarWeight)
                    equipmentRow("Safety Squat Bar", value: $ssbWeight)
                    equipmentRow("Trap/Hex Bar", value: $trapBarWeight)
                    equipmentRow("Leg Press Sled", value: $legPressWeight)
                    equipmentRow("Hack Squat Sled", value: $hackSquatWeight)
                    equipmentRow("T-Bar Row", value: $tBarWeight)
                }

                // Deload
                Section("Deload Settings") {
                    Stepper("Weight: \(deloadWeightPct)%", value: $deloadWeightPct, in: 40...90, step: 5)
                    Stepper("Volume: \(deloadVolumePct)%", value: $deloadVolumePct, in: 30...80, step: 5)
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
            .task { await loadData() }
            .sheet(isPresented: $showWeighIn) {
                weighInSheet
            }
        }
    }

    // MARK: - Weigh-In Sheet

    private var weighInSheet: some View {
        NavigationStack {
            Form {
                Section("Weight") {
                    TextField(weightUnit, value: $newWeight, format: .number)
                        .keyboardType(.decimalPad)
                }
                Section("Body Fat % (optional)") {
                    TextField("%", value: $newBodyFat, format: .number)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Log Weigh-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showWeighIn = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveWeighIn() }
                    }
                    .disabled(newWeight == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    private func equipmentRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Text(weightUnit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formatDate(_ dateStr: String?) -> String {
        guard let str = dateStr else { return "—" }
        // Simple date display
        if str.count >= 10 {
            return String(str.prefix(10))
        }
        return str
    }

    // MARK: - Data

    private func loadData() async {
        do {
            weighIns = try await APIClient.shared.get("/body-weight/", query: [.init(name: "limit", value: "10")])
        } catch {
            print("[Settings] Load error: \(error)")
        }
    }

    private func saveWeighIn() async {
        guard let w = newWeight else { return }
        let kg = weightUnit == "lbs" ? w * 0.453592 : w

        struct AddBW: Encodable {
            let weight_kg: Double
            let body_fat_pct: Double?
        }

        do {
            let entry: BodyWeightEntry = try await APIClient.shared.post(
                "/body-weight/",
                body: AddBW(weight_kg: kg, body_fat_pct: newBodyFat)
            )
            weighIns.insert(entry, at: 0)
            newWeight = nil
            newBodyFat = nil
            showWeighIn = false

            // Write to HealthKit
            if healthKitAuthorized {
                let sample = HKQuantitySample(
                    type: HKObjectType.quantityType(forIdentifier: .bodyMass)!,
                    quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg),
                    start: Date(), end: Date()
                )
                try? await healthStore.save(sample)
            }
        } catch {
            print("[Settings] Save weigh-in error: \(error)")
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
            }
        }
    }
}
