import SwiftUI
import HealthKit

// MARK: - UserDefaults Keys (shared across views via @AppStorage)

enum SettingsKey {
    static let weightUnit          = "weightUnit"
    static let heightUnit          = "heightUnit"
    static let heightInches        = "heightInches"
    static let sex                 = "sex"
    static let age                 = "age"
    static let progressionStyle    = "progressionStyle"
    static let maxWarmupSets       = "maxWarmupSets"
    static let showPlateMath       = "showPlateMath"

    // Bar weights (lbs)
    static let barbellWeight       = "barWeight_barbell"
    static let ezBarWeight         = "barWeight_ez_bar"
    static let rackableEZBarWeight = "barWeight_rackable_ez_bar"
    static let ssbWeight           = "barWeight_safety_squat_bar"
    static let trapBarWeight       = "barWeight_trap_hex_bar"

    // Machine weights (lbs)
    static let smithWeight         = "machineWeight_smith_machine"
    static let legPressWeight      = "machineWeight_leg_press"
    static let hackSquatWeight     = "machineWeight_hack_squat"
    static let tBarWeight          = "machineWeight_t_bar_row"
    static let beltSquatWeight     = "machineWeight_belt_squat"
    static let chestPressWeight    = "machineWeight_chest_press"
    static let shoulderPressWeight = "machineWeight_shoulder_press"
    static let inclinePressWeight  = "machineWeight_incline_press"
    static let declinePressWeight  = "machineWeight_decline_press"
    static let calfRaiseWeight     = "machineWeight_calf_raise"
    static let seatedRowWeight     = "machineWeight_seated_row"
    static let latPulldownWeight   = "machineWeight_lat_pulldown"
    static let pendulumSquatWeight = "machineWeight_pendulum_squat"
    static let hipThrustWeight     = "machineWeight_hip_thrust"
    static let legExtensionWeight  = "machineWeight_leg_extension"
    static let legCurlWeight       = "machineWeight_leg_curl"

    // Rest timers (seconds)
    static let upperCompound       = "rest_upperCompound"
    static let upperIsolation      = "rest_upperIsolation"
    static let lowerCompound       = "rest_lowerCompound"
    static let lowerIsolation      = "rest_lowerIsolation"

    // Deload
    static let deloadWeightPct     = "deloadWeightPct"
    static let deloadVolumePct     = "deloadVolumePct"
    static let deloadSessions      = "deloadSessions"

    // Cached body weight for calorie estimates
    static let lastBodyWeightKg    = "lastBodyWeightKg"
}

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(AuthService.self) var auth
    @State private var healthKitAuthorized = false
    @State private var healthStore = HKHealthStore()

    // Body weight
    @State private var weighIns: [BodyWeightEntry] = []
    @State private var showWeighIn = false
    @State private var loadingWeighIns = false

    // Weigh-in sheet state
    @State private var newWeight: Double? = nil
    @State private var newBodyFat: Double? = nil
    @State private var newNotes: String = ""

    // Height helper (split mode)
    @State private var heightFeet: Int = 5
    @State private var heightRemainderInches: Int = 7

    // MARK: @AppStorage — all settings

    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @AppStorage(SettingsKey.heightUnit) private var heightUnit: String = "imperial_split"
    @AppStorage(SettingsKey.heightInches) private var heightInches: Double = 67
    @AppStorage(SettingsKey.sex) private var sex: String = "male"
    @AppStorage(SettingsKey.age) private var age: Int = 0
    @AppStorage(SettingsKey.progressionStyle) private var progressionStyle: String = "rep_first"
    @AppStorage(SettingsKey.maxWarmupSets) private var maxWarmupSets: Int = 2
    @AppStorage(SettingsKey.showPlateMath) private var showPlateMath: Bool = true

    // Bar weights
    @AppStorage(SettingsKey.barbellWeight) private var barbellWeight: Double = 45
    @AppStorage(SettingsKey.ezBarWeight) private var ezBarWeight: Double = 25
    @AppStorage(SettingsKey.rackableEZBarWeight) private var rackableEZBarWeight: Double = 25
    @AppStorage(SettingsKey.ssbWeight) private var ssbWeight: Double = 65
    @AppStorage(SettingsKey.trapBarWeight) private var trapBarWeight: Double = 55

    // Machine weights
    @AppStorage(SettingsKey.smithWeight) private var smithWeight: Double = 35
    @AppStorage(SettingsKey.legPressWeight) private var legPressWeight: Double = 0
    @AppStorage(SettingsKey.hackSquatWeight) private var hackSquatWeight: Double = 0
    @AppStorage(SettingsKey.tBarWeight) private var tBarWeight: Double = 0
    @AppStorage(SettingsKey.beltSquatWeight) private var beltSquatWeight: Double = 0
    @AppStorage(SettingsKey.chestPressWeight) private var chestPressWeight: Double = 0
    @AppStorage(SettingsKey.shoulderPressWeight) private var shoulderPressWeight: Double = 0
    @AppStorage(SettingsKey.inclinePressWeight) private var inclinePressWeight: Double = 0
    @AppStorage(SettingsKey.declinePressWeight) private var declinePressWeight: Double = 0
    @AppStorage(SettingsKey.calfRaiseWeight) private var calfRaiseWeight: Double = 0
    @AppStorage(SettingsKey.seatedRowWeight) private var seatedRowWeight: Double = 0
    @AppStorage(SettingsKey.latPulldownWeight) private var latPulldownWeight: Double = 0
    @AppStorage(SettingsKey.pendulumSquatWeight) private var pendulumSquatWeight: Double = 0
    @AppStorage(SettingsKey.hipThrustWeight) private var hipThrustWeight: Double = 0
    @AppStorage(SettingsKey.legExtensionWeight) private var legExtensionWeight: Double = 0
    @AppStorage(SettingsKey.legCurlWeight) private var legCurlWeight: Double = 0

    // Rest timers
    @AppStorage(SettingsKey.upperCompound) private var upperCompound: Int = 180
    @AppStorage(SettingsKey.upperIsolation) private var upperIsolation: Int = 90
    @AppStorage(SettingsKey.lowerCompound) private var lowerCompound: Int = 240
    @AppStorage(SettingsKey.lowerIsolation) private var lowerIsolation: Int = 120

    // Deload
    @AppStorage(SettingsKey.deloadWeightPct) private var deloadWeightPct: Int = 70
    @AppStorage(SettingsKey.deloadVolumePct) private var deloadVolumePct: Int = 60
    @AppStorage(SettingsKey.deloadSessions) private var deloadSessions: Int = 0

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                profileSection
                unitsSection
                bodyWeightSection
                progressionSection
                restTimerSection
                plateMathSection
                barsSection
                machinesSection
                deloadSection
                appleHealthSection
                accountSection
            }
            .navigationTitle("Settings")
            .task { await loadData() }
            .keyboardDoneButton()
            .sheet(isPresented: $showWeighIn) {
                weighInSheet
            }
        }
    }

    // MARK: - Profile Section

    private var profileSection: some View {
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
                TextField("Age", value: Binding(
                    get: { age == 0 ? nil : age },
                    set: { age = $0 ?? 0 }
                ), format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
            }

            heightRow
        }
    }

    @ViewBuilder
    private var heightRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Height")
                Spacer()
                Picker("Unit", selection: $heightUnit) {
                    Text("ft + in").tag("imperial_split")
                    Text("inches").tag("imperial_in")
                    Text("cm").tag("metric")
                }
                .pickerStyle(.menu)
                .onChange(of: heightUnit) { _, _ in syncHeightFromInches() }
            }

            switch heightUnit {
            case "imperial_split":
                HStack(spacing: 12) {
                    Picker("Feet", selection: $heightFeet) {
                        ForEach(3...8, id: \.self) { Text("\($0) ft").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 100, height: 80)
                    .clipped()
                    .onChange(of: heightFeet) { _, _ in updateHeightFromSplit() }

                    Picker("Inches", selection: $heightRemainderInches) {
                        ForEach(0...11, id: \.self) { Text("\($0) in").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 100, height: 80)
                    .clipped()
                    .onChange(of: heightRemainderInches) { _, _ in updateHeightFromSplit() }
                }
                .frame(maxWidth: .infinity)

            case "imperial_in":
                HStack {
                    Spacer()
                    TextField("67", value: Binding(
                        get: { Int(heightInches) },
                        set: { heightInches = Double($0) }
                    ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                    Text("in")
                        .foregroundStyle(.secondary)
                }

            default: // metric cm
                HStack {
                    Spacer()
                    TextField("170", value: Binding(
                        get: { Int(heightInches * 2.54) },
                        set: { heightInches = Double($0) / 2.54 }
                    ), format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                    Text("cm")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { syncHeightFromInches() }
    }

    // MARK: - Units Section

    private var unitsSection: some View {
        Section("Units") {
            Picker("Weight Unit", selection: $weightUnit) {
                Text("lbs").tag("lbs")
                Text("kg").tag("kg")
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Body Weight Section

    private var bodyWeightSection: some View {
        Section {
            if loadingWeighIns {
                ProgressView()
            } else if weighIns.isEmpty {
                Text("No weigh-ins yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(weighIns.prefix(10)) { entry in
                    weightRow(entry)
                }
                .onDelete { offsets in
                    Task { await deleteWeighIns(at: offsets) }
                }
            }
            Button("Log Weigh-In") { showWeighIn = true }
        } header: {
            Text("Body Weight")
        } footer: {
            Text("Swipe left to delete an entry.")
                .font(.caption)
        }
    }

    private func weightRow(_ entry: BodyWeightEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(formatDate(entry.recorded_at))
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.1f %@",
                    weightUnit == "lbs" ? entry.weight_kg * 2.20462 : entry.weight_kg,
                    weightUnit))
                    .font(.subheadline.bold())
            }
            HStack(spacing: 8) {
                if let bf = entry.body_fat_pct {
                    let leanKg = entry.weight_kg * (1 - bf / 100)
                    let fatKg  = entry.weight_kg * (bf / 100)
                    let lean   = weightUnit == "lbs" ? leanKg * 2.20462 : leanKg
                    let fat    = weightUnit == "lbs" ? fatKg  * 2.20462 : fatKg
                    Text(String(format: "%.1f%% BF · LBM %.0f · Fat %.0f %@",
                                bf, lean, fat, weightUnit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = entry.notes, !notes.isEmpty {
                    Text("· \(notes)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Progression Section

    private var progressionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Progression Style")
                    .font(.subheadline)
                Picker("", selection: $progressionStyle) {
                    Text("Rep First").tag("rep_first")
                    Text("Weight First").tag("weight_first")
                }
                .pickerStyle(.segmented)
                Text(progressionStyle == "rep_first"
                    ? "Add 1 rep each session; convert to weight when you reach the top of your rep range."
                    : "Immediately translate +1 rep into a weight increase via the Epley 1RM formula.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            Stepper("Max Warmup Sets: \(maxWarmupSets)", value: $maxWarmupSets, in: 1...4)
        } header: {
            Text("Progression")
        }
    }

    // MARK: - Rest Timer Section

    private var restTimerSection: some View {
        Section("Rest Timers") {
            restRow("Upper Compound", value: $upperCompound)
            restRow("Upper Isolation", value: $upperIsolation)
            restRow("Lower Compound", value: $lowerCompound)
            restRow("Lower Isolation", value: $lowerIsolation)
        }
    }

    // MARK: - Plate Math Section

    private var plateMathSection: some View {
        Section {
            Toggle("Show Plate Math", isOn: $showPlateMath)
        } header: {
            Text("Plate Math")
        } footer: {
            Text("Shows a plate visualisation when entering weight for barbell and plate-loaded exercises.")
        }
    }

    // MARK: - Bars Section

    private var barsSection: some View {
        Section("Bar Weights (\(weightUnit))") {
            equipmentRow("Standard Barbell", lbsValue: $barbellWeight)
            equipmentRow("EZ Curl Bar", lbsValue: $ezBarWeight)
            equipmentRow("Rackable EZ Bar", lbsValue: $rackableEZBarWeight)
            equipmentRow("Safety Squat Bar", lbsValue: $ssbWeight)
            equipmentRow("Trap / Hex Bar", lbsValue: $trapBarWeight)
        }
    }

    // MARK: - Machines Section

    private var machinesSection: some View {
        Section("Plate-Loaded Machines (\(weightUnit))") {
            equipmentRow("Smith Machine", lbsValue: $smithWeight)
            equipmentRow("Leg Press", lbsValue: $legPressWeight)
            equipmentRow("Hack Squat", lbsValue: $hackSquatWeight)
            equipmentRow("T-Bar Row", lbsValue: $tBarWeight)
            equipmentRow("Belt Squat", lbsValue: $beltSquatWeight)
            equipmentRow("Chest Press", lbsValue: $chestPressWeight)
            equipmentRow("Shoulder Press", lbsValue: $shoulderPressWeight)
            equipmentRow("Incline Press", lbsValue: $inclinePressWeight)
            equipmentRow("Decline Press", lbsValue: $declinePressWeight)
            equipmentRow("Calf Raise", lbsValue: $calfRaiseWeight)
            equipmentRow("Seated Row", lbsValue: $seatedRowWeight)
            equipmentRow("Lat Pulldown", lbsValue: $latPulldownWeight)
            equipmentRow("Pendulum Squat", lbsValue: $pendulumSquatWeight)
            equipmentRow("Hip Thrust Machine", lbsValue: $hipThrustWeight)
            equipmentRow("Leg Extension", lbsValue: $legExtensionWeight)
            equipmentRow("Leg Curl", lbsValue: $legCurlWeight)
        }
    }

    // MARK: - Deload Section

    private var deloadSection: some View {
        Section {
            Picker("Sessions", selection: $deloadSessions) {
                Text("Auto").tag(0)
                ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
            }
            Stepper("Weight reduction: \(deloadWeightPct)%",
                    value: $deloadWeightPct, in: 40...90, step: 5)
            Stepper("Volume reduction: \(deloadVolumePct)%",
                    value: $deloadVolumePct, in: 30...80, step: 5)
        } header: {
            Text("Deload")
        } footer: {
            Text("Auto: deload is triggered based on cumulative training fatigue.")
        }
    }

    // MARK: - Apple Health Section

    @ViewBuilder
    private var appleHealthSection: some View {
        if HKHealthStore.isHealthDataAvailable() {
            Section("Apple Health") {
                if healthKitAuthorized {
                    HStack {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Text("Syncing weight, workouts & nutrition")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Connect Apple Health") {
                        requestHealthKitPermissions()
                    }
                }
            }
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                auth.logout()
            }
        }
    }

    // MARK: - Weigh-In Sheet

    private var weighInSheet: some View {
        NavigationStack {
            Form {
                Section("Weight (\(weightUnit))") {
                    TextField(weightUnit == "lbs" ? "e.g. 185.5" : "e.g. 84.0",
                              value: $newWeight, format: .number)
                        .keyboardType(.decimalPad)
                }
                Section("Body Fat % (optional)") {
                    TextField("e.g. 15.5", value: $newBodyFat, format: .number)
                        .keyboardType(.decimalPad)
                }
                Section("Notes (optional)") {
                    TextField("How are you feeling…", text: $newNotes, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let w = newWeight, let bf = newBodyFat, bf > 0, bf < 100 {
                    let kg    = weightUnit == "lbs" ? w * 0.453592 : w
                    let leanKg = kg * (1 - bf / 100)
                    let fatKg  = kg * (bf / 100)
                    let lean  = weightUnit == "lbs" ? leanKg * 2.20462 : leanKg
                    let fat   = weightUnit == "lbs" ? fatKg  * 2.20462 : fatKg
                    Section("Body Composition") {
                        HStack {
                            Text("Lean Mass")
                            Spacer()
                            Text(String(format: "%.1f %@", lean, weightUnit))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Fat Mass")
                            Spacer()
                            Text(String(format: "%.1f %@", fat, weightUnit))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Log Weigh-In")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showWeighIn = false
                        resetWeighInForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveWeighIn() }
                    }
                    .disabled(newWeight == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Helpers

    /// Returns a display-unit Binding backed by a lbs-stored @AppStorage value
    private func equipmentRow(_ label: String, lbsValue: Binding<Double>) -> some View {
        let display = Binding<Double>(
            get: { weightUnit == "kg" ? lbsValue.wrappedValue * 0.453592 : lbsValue.wrappedValue },
            set: { lbsValue.wrappedValue = weightUnit == "kg" ? $0 / 0.453592 : $0 }
        )
        return HStack {
            Text(label)
            Spacer()
            TextField("0", value: display, format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 65)
            Text(weightUnit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func restRow(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(formatSeconds(value.wrappedValue))
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
            Stepper("", value: value, in: 30...600, step: 15)
                .labelsHidden()
        }
    }

    private func formatSeconds(_ s: Int) -> String {
        let m = s / 60
        let r = s % 60
        return r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }

    private func formatDate(_ dateStr: String?) -> String {
        guard let str = dateStr, str.count >= 10 else { return "—" }
        let sub = String(str.prefix(10))
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: sub) {
            let out = DateFormatter()
            out.dateStyle = .medium
            return out.string(from: d)
        }
        return sub
    }

    private func syncHeightFromInches() {
        heightFeet = Int(heightInches) / 12
        heightRemainderInches = Int(heightInches) % 12
    }

    private func updateHeightFromSplit() {
        heightInches = Double(heightFeet * 12 + heightRemainderInches)
    }

    private func resetWeighInForm() {
        newWeight  = nil
        newBodyFat = nil
        newNotes   = ""
    }

    // MARK: - Data Actions

    private func loadData() async {
        loadingWeighIns = true
        do {
            weighIns = try await APIClient.shared.get(
                "/body-weight/",
                query: [.init(name: "limit", value: "10")]
            )
        } catch {
            print("[Settings] Load weighIns error: \(error)")
        }
        loadingWeighIns = false

        if HKHealthStore.isHealthDataAvailable() {
            let status = healthStore.authorizationStatus(
                for: HKObjectType.quantityType(forIdentifier: .bodyMass)!)
            await MainActor.run { healthKitAuthorized = (status == .sharingAuthorized) }
        }
    }

    private func saveWeighIn() async {
        guard let w = newWeight else { return }
        let kg = weightUnit == "lbs" ? w * 0.453592 : w

        struct AddBW: Encodable {
            let weight_kg: Double
            let body_fat_pct: Double?
            let notes: String?
        }

        do {
            let entry: BodyWeightEntry = try await APIClient.shared.post(
                "/body-weight/",
                body: AddBW(
                    weight_kg: kg,
                    body_fat_pct: newBodyFat,
                    notes: newNotes.isEmpty ? nil : newNotes
                )
            )
            await MainActor.run {
                weighIns.insert(entry, at: 0)
                showWeighIn = false
                resetWeighInForm()
                // Cache for calorie estimates
                UserDefaults.standard.set(kg, forKey: SettingsKey.lastBodyWeightKg)
            }

            // Mirror to HealthKit
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

    private func deleteWeighIns(at offsets: IndexSet) async {
        let displayed = Array(weighIns.prefix(10))
        for i in offsets {
            let entry = displayed[i]
            do {
                try await APIClient.shared.delete("/body-weight/\(entry.id)")
                if let idx = weighIns.firstIndex(where: { $0.id == entry.id }) {
                    await MainActor.run { weighIns.remove(at: idx) }
                }
            } catch {
                print("[Settings] Delete weigh-in error: \(error)")
            }
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
        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { success, _ in
            DispatchQueue.main.async { healthKitAuthorized = success }
        }
    }
}
