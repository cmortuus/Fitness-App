import SwiftUI

// MARK: - Local models for plan creation

private struct CreatePlanExercise: Identifiable {
    let id = UUID()
    let exercise: Exercise
    var sets: Int = 3
    var reps: Int = 10
    var restSeconds: Int = 90
    var startingWeightKg: Double? = nil
}

private struct CreatePlanDay: Identifiable {
    let id = UUID()
    var dayNumber: Int
    var dayName: String
    var exercises: [CreatePlanExercise] = []
}

// MARK: - Create Plan View

struct CreatePlanView: View {
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"

    // Step navigation: 1 = basic info, 2 = configure days
    @State private var step = 1

    // Basic info
    @State private var planName = ""
    @State private var blockType = "hypertrophy"
    @State private var numDays = 3
    @State private var durationWeeks = 4

    // Days
    @State private var days: [CreatePlanDay] = []

    // Exercise picker
    @State private var allExercises: [Exercise] = []
    @State private var showPickerForDay: Int? = nil   // dayNumber
    @State private var editingExercise: (Int, UUID)? = nil // (dayNumber, exercise.id)

    // Saving state
    @State private var saving = false
    @State private var errorMessage: String? = nil

    private let blockTypes: [(value: String, label: String)] = [
        ("hypertrophy", "Hypertrophy"),
        ("strength", "Strength"),
        ("powerlifting", "Powerlifting"),
        ("maintenance", "Maintenance"),
        ("cutting", "Cutting"),
        ("peaking", "Peaking"),
        ("deload", "Deload"),
        ("other", "Other"),
    ]

    private var kgToLbs: Double { 2.20462 }
    private var lbsToKg: Double { 1.0 / kgToLbs }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if step == 1 { basicInfoStep }
                else          { configureDaysStep }
            }
            .navigationTitle(step == 1 ? "New Plan" : planName.isEmpty ? "Configure Days" : planName)
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar { toolbarContent }
            .sheet(item: $showPickerForDay.map(
                get: { $0.map { Identified(value: $0) } },
                set: { showPickerForDay = $0?.value }
            )) { item in
                ExercisePickerView(allExercises: allExercises) { exercise, setCount in
                    addExercise(exercise, sets: setCount, toDayNumber: item.value)
                    showPickerForDay = nil
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
            .task {
                if allExercises.isEmpty {
                    if let exercises: [Exercise] = try? await APIClient.shared.get("/exercises/") {
                        allExercises = exercises
                    }
                }
            }
        }
    }

    // MARK: - Step 1: Basic Info

    private var basicInfoStep: some View {
        Form {
            Section("Plan Details") {
                TextField("Plan name (e.g. Push Pull Legs)", text: $planName)

                Picker("Block Type", selection: $blockType) {
                    ForEach(blockTypes, id: \.value) { bt in
                        Text(bt.label).tag(bt.value)
                    }
                }

                Stepper("Duration: \(durationWeeks) week\(durationWeeks == 1 ? "" : "s")",
                        value: $durationWeeks, in: 1...52)
            }

            Section {
                Stepper("Days per week: \(numDays)", value: $numDays, in: 1...7)
            } footer: {
                Text("You'll configure exercises for each day in the next step.")
            }

            Section {
                Button(action: goToStep2) {
                    HStack {
                        Spacer()
                        Label("Configure Days", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(planName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Step 2: Configure Days

    private var configureDaysStep: some View {
        List {
            ForEach($days) { $day in
                Section {
                    // Day name row
                    HStack {
                        TextField("Day name (e.g. Push, Upper A…)", text: $day.dayName)
                            .font(.subheadline.bold())
                    }

                    // Exercise rows
                    ForEach($day.exercises) { $ex in
                        exerciseRow(day: day, ex: $ex)
                    }
                    .onDelete { offsets in
                        if let idx = days.firstIndex(where: { $0.id == day.id }) {
                            days[idx].exercises.remove(atOffsets: offsets)
                        }
                    }

                    // Add exercise button
                    Button {
                        showPickerForDay = day.dayNumber
                    } label: {
                        Label("Add Exercise", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                } header: {
                    Text("Day \(day.dayNumber)")
                        .font(.caption.bold().uppercaseSmallCaps())
                }
            }

            Section {
                Button(action: { Task { await savePlan(isDraft: false) } }) {
                    HStack {
                        Spacer()
                        if saving {
                            ProgressView()
                        } else {
                            Label("Create Plan", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(saving || !hasAtLeastOneExercise)

                Button(action: { Task { await savePlan(isDraft: true) } }) {
                    HStack {
                        Spacer()
                        Text("Save as Draft")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .disabled(saving)
            } footer: {
                if !hasAtLeastOneExercise {
                    Text("Add at least one exercise to create the plan.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func exerciseRow(day: CreatePlanDay, ex: Binding<CreatePlanExercise>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ex.wrappedValue.exercise.display_name ?? "Exercise")
                .font(.subheadline.bold())
                .lineLimit(2)

            // Sets / Reps / Rest in a grid layout
            HStack(spacing: 0) {
                // Sets
                VStack(spacing: 4) {
                    Text("Sets").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Button { if ex.wrappedValue.sets > 1 { ex.sets.wrappedValue -= 1 } } label: {
                            Image(systemName: "minus").font(.caption2)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                        Text("\(ex.wrappedValue.sets)")
                            .font(.subheadline.bold().monospacedDigit())
                            .frame(width: 24)
                        Button { if ex.wrappedValue.sets < 20 { ex.sets.wrappedValue += 1 } } label: {
                            Image(systemName: "plus").font(.caption2)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
                .frame(maxWidth: .infinity)

                // Reps
                VStack(spacing: 4) {
                    Text("Reps").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Button { if ex.wrappedValue.reps > 1 { ex.reps.wrappedValue -= 1 } } label: {
                            Image(systemName: "minus").font(.caption2)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                        Text("\(ex.wrappedValue.reps)")
                            .font(.subheadline.bold().monospacedDigit())
                            .frame(width: 24)
                        Button { if ex.wrappedValue.reps < 50 { ex.reps.wrappedValue += 1 } } label: {
                            Image(systemName: "plus").font(.caption2)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
                .frame(maxWidth: .infinity)

                // Rest
                VStack(spacing: 4) {
                    Text("Rest").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Button { if ex.wrappedValue.restSeconds > 30 { ex.restSeconds.wrappedValue -= 30 } } label: {
                            Image(systemName: "minus").font(.caption2)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                        Text(formatRest(ex.wrappedValue.restSeconds))
                            .font(.caption.bold().monospacedDigit())
                            .frame(width: 40)
                        Button { if ex.wrappedValue.restSeconds < 600 { ex.restSeconds.wrappedValue += 30 } } label: {
                            Image(systemName: "plus").font(.caption2)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Starting weight (optional)
            HStack {
                Text("Starting weight").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                TextField("optional (\(weightUnit))",
                    value: Binding(
                        get: {
                            guard let kg = ex.wrappedValue.startingWeightKg else { return nil as Double? }
                            return weightUnit == "lbs" ? kg * kgToLbs : kg
                        },
                        set: { val in
                            if let v = val {
                                ex.startingWeightKg.wrappedValue = weightUnit == "lbs" ? v * lbsToKg : v
                            } else {
                                ex.startingWeightKg.wrappedValue = nil
                            }
                        }
                    ),
                    format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        if step == 2 {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { step = 1 }
            }
        }
    }

    // MARK: - Helpers

    private var hasAtLeastOneExercise: Bool {
        days.contains { !$0.exercises.isEmpty }
    }

    private func formatRest(_ seconds: Int) -> String {
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return s == 0 ? "\(m)m" : "\(m)m\(s)s"
        }
        return "\(seconds)s"
    }

    private func goToStep2() {
        // Build day placeholders if not already done
        if days.count != numDays {
            let defaultNames = ["Push", "Pull", "Legs", "Upper", "Lower", "Full Body", "Accessory"]
            days = (1...numDays).map { i in
                CreatePlanDay(
                    dayNumber: i,
                    dayName: i <= defaultNames.count ? defaultNames[i - 1] : "Day \(i)"
                )
            }
        }
        step = 2
    }

    private func addExercise(_ exercise: Exercise, sets: Int, toDayNumber dayNumber: Int) {
        guard let idx = days.firstIndex(where: { $0.dayNumber == dayNumber }) else { return }
        days[idx].exercises.append(CreatePlanExercise(exercise: exercise, sets: sets))
    }

    private func savePlan(isDraft: Bool) async {
        saving = true
        do {
            struct PlanPayload: Encodable {
                let name: String
                let description: String?
                let block_type: String
                let duration_weeks: Int
                let number_of_days: Int
                let days: [DayPayload]
                let auto_progression: Bool
                let is_draft: Bool
            }
            struct DayPayload: Encodable {
                let day_number: Int
                let day_name: String
                let exercises: [ExercisePayload]
            }
            struct ExercisePayload: Encodable {
                let exercise_id: Int
                let sets: Int
                let reps: Int
                let starting_weight_kg: Double
                let progression_type: String
                let rest_seconds: Int
            }

            let dayPayloads = days.map { day in
                DayPayload(
                    day_number: day.dayNumber,
                    day_name: day.dayName,
                    exercises: day.exercises.map { ex in
                        ExercisePayload(
                            exercise_id: ex.exercise.id,
                            sets: ex.sets,
                            reps: ex.reps,
                            starting_weight_kg: ex.startingWeightKg ?? 0,
                            progression_type: "reps",
                            rest_seconds: ex.restSeconds
                        )
                    }
                )
            }

            let payload = PlanPayload(
                name: planName.trimmingCharacters(in: .whitespaces),
                description: nil,
                block_type: blockType,
                duration_weeks: durationWeeks,
                number_of_days: numDays,
                days: dayPayloads,
                auto_progression: true,
                is_draft: isDraft
            )

            struct PlanResponse: Decodable { let id: Int; let name: String }
            let _: PlanResponse = try await APIClient.shared.post("/plans/", body: payload)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}

// MARK: - Helper: Optional Binding wrapper for sheet(item:)

private struct Identified<T>: Identifiable {
    let value: T
    var id: String { "\(value)" }
}

private extension Binding where Value == Int? {
    func map<T>(get: @escaping (Int?) -> T?, set: @escaping (T?) -> Void) -> Binding<T?> {
        Binding<T?>(get: { get(wrappedValue) }, set: { set($0) })
    }
}
