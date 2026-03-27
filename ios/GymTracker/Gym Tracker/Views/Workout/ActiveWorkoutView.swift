import SwiftUI
import AudioToolbox
import UserNotifications

// MARK: - Active Workout View

struct ActiveWorkoutView: View {
    let planId: Int?
    let planName: String
    var dayNumber: Int = 1

    @Environment(\.dismiss) var dismiss
    @State private var sessionId: Int?
    @State private var exercises: [UIExercise] = []
    @State private var allExercises: [Exercise] = []
    @State private var loading = true
    @State private var error: String?
    @State private var elapsed = 0
    @State private var clockTimer: Timer?
    @State private var clockPaused = false

    // Rest timer
    @State private var restActive = false
    @State private var restSecs = 0
    @State private var restTimer: Timer?
    @State private var restEndTime: Date?
    // restDurations is now a computed property (currentRestDurations) using @AppStorage values

    // Finish state
    @State private var allDone = false
    @State private var finishing = false
    @State private var finished = false
    @State private var showCancelConfirm = false

    // Exercise picker + history
    @State private var showAddExercise = false
    @State private var swapTarget: UIExercise? = nil
    @State private var historyExercise: UIExercise? = nil

    // PR celebration
    @State private var prCelebration: PR? = nil
    @State private var showConfetti = false
    @State private var endOfWorkoutPRs: [PR] = []

    // Autoregulation
    @State private var feedback: [Int: ExerciseFeedback] = [:] // keyed by exerciseId
    @State private var recoveryAskedMuscles: Set<String> = []
    @State private var showRecoveryFor: Int? = nil // exerciseId
    @State private var showEffortFor: Int? = nil // exerciseId

    // Plate math
    @State private var focusedExercise: UIExercise? = nil
    @State private var focusedWeight: Double? = nil

    // Settings (synced with SettingsView via shared UserDefaults keys)
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @AppStorage(SettingsKey.showPlateMath) private var showPlateMath: Bool = true

    // Bar weights (lbs) — used for plate math
    @AppStorage(SettingsKey.barbellWeight) private var barbellWeightSetting: Double = 45
    @AppStorage(SettingsKey.ezBarWeight) private var ezBarWeightSetting: Double = 25
    @AppStorage(SettingsKey.rackableEZBarWeight) private var rackableEZBarWeightSetting: Double = 25
    @AppStorage(SettingsKey.ssbWeight) private var ssbWeightSetting: Double = 65
    @AppStorage(SettingsKey.trapBarWeight) private var trapBarWeightSetting: Double = 55
    @AppStorage(SettingsKey.smithWeight) private var smithWeightSetting: Double = 35
    @AppStorage(SettingsKey.legPressWeight) private var legPressWeightSetting: Double = 0
    @AppStorage(SettingsKey.hackSquatWeight) private var hackSquatWeightSetting: Double = 0
    @AppStorage(SettingsKey.tBarWeight) private var tBarWeightSetting: Double = 0
    @AppStorage(SettingsKey.beltSquatWeight) private var beltSquatWeightSetting: Double = 0

    // Rest timers
    @AppStorage(SettingsKey.upperCompound) private var upperCompoundRest: Int = 180
    @AppStorage(SettingsKey.upperIsolation) private var upperIsolationRest: Int = 90
    @AppStorage(SettingsKey.lowerCompound) private var lowerCompoundRest: Int = 240
    @AppStorage(SettingsKey.lowerIsolation) private var lowerIsolationRest: Int = 120

    private let kgToLbs = 2.20462
    private let lbsToKg = 0.453592

    private var currentRestDurations: RestDurations {
        RestDurations(
            upperCompound: upperCompoundRest,
            upperIsolation: upperIsolationRest,
            lowerCompound: lowerCompoundRest,
            lowerIsolation: lowerIsolationRest
        )
    }

    /// Bar/sled weight for a given exercise, respecting user settings
    private func settingsBarWeight(for exercise: UIExercise) -> Double {
        let lbs: Double
        switch exercise.equipmentType {
        case "barbell":           lbs = barbellWeightSetting
        case "ez_bar":            lbs = ezBarWeightSetting
        case "rackable_ez_bar":   lbs = rackableEZBarWeightSetting
        case "safety_squat_bar":  lbs = ssbWeightSetting
        case "trap_hex_bar":      lbs = trapBarWeightSetting
        case "smith_machine":     lbs = smithWeightSetting
        case "leg_press":         lbs = legPressWeightSetting
        case "hack_squat":        lbs = hackSquatWeightSetting
        case "t_bar_row":         lbs = tBarWeightSetting
        case "belt_squat":        lbs = beltSquatWeightSetting
        default:                  lbs = barWeight(for: exercise) // fallback to UIModels defaults
        }
        return weightUnit == "kg" ? lbs * lbsToKg : lbs
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                if loading {
                    ProgressView("Starting workout...")
                } else if finished {
                    WorkoutSummaryView(
                        workoutName: planName,
                        duration: elapsed,
                        exercises: exercises,
                        prs: endOfWorkoutPRs,
                        sessionId: sessionId,
                        planId: planId,
                        onDismiss: { dismiss() }
                    )
                } else if let error {
                    errorView(error)
                } else {
                    workoutContent
                }

                // PR celebration overlay
                if let pr = prCelebration {
                    VStack {
                        prToast(pr)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                }

                // Confetti
                if showConfetti {
                    ConfettiView()
                        .allowsHitTesting(false)
                        .zIndex(99)
                }
            }
            .navigationTitle(planName)
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
        }
        .task { await startWorkout() }
        .onDisappear { stopTimers() }
        .sheet(item: $historyExercise) { ex in
            ExerciseHistoryView(exerciseId: ex.id, exerciseName: ex.name)
        }
        .sheet(isPresented: $showAddExercise) {
            ExercisePickerView(
                allExercises: allExercises,
                onSelect: { ex, count in addExercise(ex, setCount: count) },
                swapMode: swapTarget != nil,
                swapExercise: swapTarget
            )
        }
    }

    // MARK: - Error View

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title).foregroundStyle(.orange)
            Text(msg).font(.caption).multilineTextAlignment(.center)
            Button("Dismiss") { dismiss() }.buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - PR Toast

    private func prToast(_ pr: PR) -> some View {
        VStack(spacing: 4) {
            Text("🎉🏆🎉").font(.title)
            Text("\(pr.type == "weight" ? "Weight PR" : "Rep PR")!")
                .font(.headline.bold())
            Text(pr.exerciseName).font(.caption).foregroundStyle(.secondary)
            Text(pr.value).font(.title3.bold())
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
                .opacity(0.9)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
        .shadow(radius: 10)
    }

    // MARK: - Workout Content

    private var workoutContent: some View {
        VStack(spacing: 0) {
            // Progress + header
            workoutHeader

            // Rest timer banner
            if restActive {
                restTimerBanner
            }

            // Exercise list
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(exercises.indices, id: \.self) { exIdx in
                        exerciseCard(exIdx: exIdx)
                    }

                    // Add exercise button
                    Button(action: { swapTarget = nil; showAddExercise = true }) {
                        Label("Add Exercise", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.vertical, 8)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)

            // Bottom bar — finish or plate math
            bottomBar
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { showCancelConfirm = true }
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog("Cancel workout?", isPresented: $showCancelConfirm) {
            Button("Discard Workout", role: .destructive) { Task { await cancelWorkout() } }
            Button("Keep Working", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var workoutHeader: some View {
        VStack(spacing: 4) {
            // Progress bar
            let total = exercises.flatMap(\.sets).count
            let done = exercises.flatMap(\.sets).filter { $0.done || $0.skipped }.count
            let pct = total > 0 ? Double(done) / Double(total) : 0

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.blue, .green], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * pct, height: 3)
            }
            .frame(height: 3)

            HStack {
                // Elapsed clock (tappable to pause)
                Button(action: { clockPaused.toggle() }) {
                    HStack(spacing: 4) {
                        if clockPaused {
                            Image(systemName: "pause.fill").font(.caption2)
                        }
                        Text(formatTime(elapsed))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(clockPaused ? .orange : .secondary)
                }

                Spacer()

                // Set counter
                Text("\(done)/\(total) sets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Rest Timer Banner

    private var restTimerBanner: some View {
        HStack {
            Image(systemName: "timer").foregroundStyle(.blue)
            Text(formatTime(restSecs))
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(restSecs <= 10 ? .orange : .primary)
            Spacer()
            Button(action: { adjustRest(-15) }) {
                Text("-15s").font(.caption)
            }
            .buttonStyle(.bordered)
            Button(action: { adjustRest(15) }) {
                Text("+15s").font(.caption)
            }
            .buttonStyle(.bordered)
            Button("Skip") { skipRest() }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.1))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            // Plate math (when weight input focused and setting is on)
            if showPlateMath,
               let ex = focusedExercise, let w = focusedWeight,
               shouldShowPlates(for: ex), w > settingsBarWeight(for: ex) {
                PlateVisualView(
                    totalWeight: w,
                    barWeight: settingsBarWeight(for: ex),
                    isLbs: weightUnit == "lbs",
                    oneSided: isOneSided(ex)
                )
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
            }

            // Finish button
            if allDone {
                Button(action: finishWorkout) {
                    HStack {
                        Image(systemName: "checkmark")
                        Text(finishing ? "Saving..." : "Finish Workout")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(finishing)
                .padding()
            }
        }
    }

    // MARK: - Exercise Card

    private func exerciseCard(exIdx: Int) -> some View {
        let exercise = exercises[exIdx]
        let allSetsDone = exercise.sets.allSatisfy { $0.done || $0.skipped }

        return VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.headline)
                        .foregroundStyle(allSetsDone ? .green : .primary)
                    if !exercise.muscleGroup.isEmpty {
                        Text(exercise.muscleGroup)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Reorder arrows
                if exIdx > 0 {
                    Button(action: { moveExercise(from: exIdx, direction: -1) }) {
                        Image(systemName: "chevron.up").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                if exIdx < exercises.count - 1 {
                    Button(action: { moveExercise(from: exIdx, direction: 1) }) {
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                // Menu (history, swap, remove)
                Menu {
                    Button(action: { historyExercise = exercise }) {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    Button(action: { swapTarget = exercise; showAddExercise = true }) {
                        Label("Swap Exercise", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive, action: { removeExercise(exIdx) }) {
                        Label("Remove Exercise", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            // Notes
            if let note = exercise.note, !note.isEmpty {
                Text("📝 \(note)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Column headers
            HStack(spacing: 0) {
                Text("").frame(width: 30)
                Text("Type").frame(width: 60)
                Text(weightUnit).frame(maxWidth: .infinity)
                Text("Reps").frame(maxWidth: .infinity)
                Text("").frame(width: exercise.isUnilateral ? 90 : 70)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // Set rows
            ForEach(exercises[exIdx].sets.indices, id: \.self) { sIdx in
                setRow(exIdx: exIdx, sIdx: sIdx)
            }

            // Add/remove set + warmup buttons
            HStack(spacing: 8) {
                Button(action: { addSet(exIdx: exIdx) }) {
                    Label("Add Set", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if exercises[exIdx].sets.count > 1 {
                    Button(action: { removeLastSet(exIdx: exIdx) }) {
                        Label("Remove", systemImage: "minus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }

                if shouldShowPlates(for: exercise) && !exercise.sets.contains(where: { $0.setType == .warmup }) {
                    Button(action: { generateWarmups(exIdx: exIdx) }) {
                        Label("Warmups", systemImage: "flame")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }
            }

            // Recovery prompt
            if showRecoveryFor == exercise.id {
                recoveryPrompt(exerciseId: exercise.id, muscleGroup: exercise.muscleGroup)
            }

            // Effort prompt
            if showEffortFor == exercise.id {
                effortPrompt(exerciseId: exercise.id)
            }

            // Feedback badge
            if let fb = feedback[exercise.id], fb.submitted {
                feedbackBadge(fb)
            }
        }
        .padding()
        .background(Color(.systemGray6).opacity(allSetsDone ? 0.3 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Set Row

    @ViewBuilder
    private func setRow(exIdx: Int, sIdx: Int) -> some View {
        if exercises[exIdx].isUnilateral {
            unilateralSetRows(exIdx: exIdx, sIdx: sIdx)
        } else {
            bilateralSetRow(exIdx: exIdx, sIdx: sIdx)
        }
    }

    /// Standard bilateral set row
    private func bilateralSetRow(exIdx: Int, sIdx: Int) -> some View {
        let set = exercises[exIdx].sets[sIdx]
        let exercise = exercises[exIdx]

        return HStack(spacing: 4) {
            // Set number
            Text("\(set.setNumber)")
                .font(.caption.bold())
                .frame(width: 30)
                .foregroundStyle(set.done ? .green : set.skipped ? .orange : set.setType.color)

            // Set type picker
            Menu {
                ForEach(SetType.available(forSetNumber: set.setNumber), id: \.self) { type in
                    Button(type.label) {
                        exercises[exIdx].sets[sIdx].setType = type
                    }
                }
            } label: {
                Text(set.setType.label)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 60)
                    .foregroundStyle(set.setType.color)
            }
            .disabled(set.done || set.skipped)

            // Weight
            TextField(weightUnit, value: Binding(
                get: { exercises[exIdx].sets[sIdx].weight },
                set: { newVal in
                    exercises[exIdx].sets[sIdx].weight = newVal
                    if let w = newVal, let rm = exercises[exIdx].sets[sIdx].oneRM, w > 0, rm > 0 {
                        let estReps = Int((rm / w - 1) * 30)
                        if estReps >= 1 && estReps <= 50 {
                            exercises[exIdx].sets[sIdx].reps = estReps
                        }
                    }
                    focusedExercise = exercise
                    focusedWeight = newVal
                }
            ), format: .number.precision(.fractionLength(1)))
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .disabled(set.done || set.skipped || set.setType == .myoRepMatch)
            .onTapGesture { focusedExercise = exercise; focusedWeight = set.weight }

            // Reps
            TextField("reps", value: Binding(
                get: { exercises[exIdx].sets[sIdx].reps },
                set: { exercises[exIdx].sets[sIdx].reps = $0 }
            ), format: .number)
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .disabled(set.done || set.skipped || set.setType == .myoRepMatch)

            // Action buttons
            if set.done {
                Button(action: { undoSet(exIdx: exIdx, sIdx: sIdx) }) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .frame(width: 70)
            } else if set.skipped {
                Button(action: { unskipSet(exIdx: exIdx, sIdx: sIdx) }) {
                    Text("Skip").font(.caption).strikethrough().foregroundStyle(.orange)
                }
                .frame(width: 70)
            } else if set.saving {
                ProgressView().frame(width: 70)
            } else {
                HStack(spacing: 6) {
                    Button(action: { Task { await completeSet(exIdx: exIdx, sIdx: sIdx) } }) {
                        Image(systemName: "checkmark").font(.body.bold())
                    }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                    .disabled(!canComplete(set: set, exercise: exercise))

                    Button(action: { skipSet(exIdx: exIdx, sIdx: sIdx) }) {
                        Image(systemName: "forward.fill").font(.caption2)
                    }
                    .buttonStyle(.bordered).controlSize(.mini).tint(.gray)
                }
                .frame(width: 70)
            }
        }
        .padding(.vertical, 2)
        .opacity(set.skipped ? 0.5 : 1)
    }

    /// Unilateral set: two rows (L + R) per set, each acting independently
    private func unilateralSetRows(exIdx: Int, sIdx: Int) -> some View {
        let set = exercises[exIdx].sets[sIdx]
        let exercise = exercises[exIdx]

        return VStack(spacing: 1) {
            ForEach([true, false], id: \.self) { isLeft in
                let sideDone   = isLeft ? set.doneLeft  : set.doneRight
                let sideReps   = isLeft ? set.repsLeft  : set.repsRight
                let placeholder = isLeft ? "L" : "R"

                HStack(spacing: 4) {
                    // Set number (only on L row)
                    Group {
                        if isLeft {
                            Text("\(set.setNumber)")
                                .foregroundStyle(set.done ? .green : set.skipped ? .orange : set.setType.color)
                        } else {
                            Text("")
                        }
                    }
                    .font(.caption.bold())
                    .frame(width: 30)

                    // Type picker (L row: interactive; R row: label only)
                    if isLeft {
                        Menu {
                            ForEach(SetType.available(forSetNumber: set.setNumber), id: \.self) { type in
                                Button(type.label) { exercises[exIdx].sets[sIdx].setType = type }
                            }
                        } label: {
                            Text(set.setType.label).font(.caption2).lineLimit(1).frame(width: 60)
                                .foregroundStyle(set.setType.color)
                        }
                        .disabled(set.done || set.skipped)
                    } else {
                        Text(set.setType.label).font(.caption2).lineLimit(1).frame(width: 60)
                            .foregroundStyle(set.setType.color.opacity(0.5))
                    }

                    // Weight (shared between L/R)
                    TextField(weightUnit, value: Binding(
                        get: { exercises[exIdx].sets[sIdx].weight },
                        set: { newVal in
                            exercises[exIdx].sets[sIdx].weight = newVal
                            if let w = newVal, let rm = exercises[exIdx].sets[sIdx].oneRM, w > 0, rm > 0 {
                                let estReps = Int((rm / w - 1) * 30)
                                if estReps >= 1 && estReps <= 50 {
                                    exercises[exIdx].sets[sIdx].repsLeft  = estReps
                                    exercises[exIdx].sets[sIdx].repsRight = estReps
                                }
                            }
                            focusedExercise = exercise
                            focusedWeight = newVal
                        }
                    ), format: .number.precision(.fractionLength(1)))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .disabled(set.done || sideDone || set.skipped)

                    // Per-side reps
                    TextField(placeholder, value: Binding(
                        get: { isLeft ? exercises[exIdx].sets[sIdx].repsLeft
                                      : exercises[exIdx].sets[sIdx].repsRight },
                        set: { v in
                            if isLeft { exercises[exIdx].sets[sIdx].repsLeft  = v }
                            else      { exercises[exIdx].sets[sIdx].repsRight = v }
                        }
                    ), format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .disabled(set.done || sideDone || set.skipped)

                    // Per-side action buttons
                    if set.done {
                        // Both done — undo whole set only on L row, blank on R
                        if isLeft {
                            Button(action: { undoSet(exIdx: exIdx, sIdx: sIdx) }) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                            .frame(width: 70)
                        } else {
                            Text("").frame(width: 70)
                        }
                    } else if set.skipped {
                        if isLeft {
                            Button(action: { unskipSet(exIdx: exIdx, sIdx: sIdx) }) {
                                Text("Skip").font(.caption).strikethrough().foregroundStyle(.orange)
                            }
                            .frame(width: 70)
                        } else {
                            Text("").frame(width: 70)
                        }
                    } else if sideDone {
                        Button(action: {
                            if isLeft { exercises[exIdx].sets[sIdx].doneLeft  = false }
                            else      { exercises[exIdx].sets[sIdx].doneRight = false }
                        }) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.6))
                        }
                        .frame(width: 70)
                    } else if set.saving {
                        ProgressView().frame(width: 70)
                    } else {
                        HStack(spacing: 4) {
                            Button(action: { Task { await completeSide(exIdx: exIdx, sIdx: sIdx, isLeft: isLeft) } }) {
                                Image(systemName: "checkmark").font(.body.bold())
                            }
                            .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                            .disabled((sideReps ?? 0) < 1)

                            Button(action: { skipSet(exIdx: exIdx, sIdx: sIdx) }) {
                                Image(systemName: "forward.fill").font(.caption2)
                            }
                            .buttonStyle(.bordered).controlSize(.mini).tint(.gray)
                        }
                        .frame(width: 70)
                    }

                    // Side label
                    Text(isLeft ? "L" : "R")
                        .font(.caption.bold())
                        .foregroundStyle(sideDone ? .green : .secondary)
                        .frame(width: 20)
                }
                .padding(.vertical, 2)
                .opacity((set.skipped || (set.done && !isLeft)) ? 0.4 : 1)
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.3)
        }
    }

    // MARK: - Autoregulation Views

    private func recoveryPrompt(exerciseId: Int, muscleGroup: String) -> some View {
        VStack(spacing: 8) {
            Text("How recovered is your \(muscleGroup)?")
                .font(.caption.bold())
            HStack(spacing: 12) {
                ForEach(RecoveryRating.allCases, id: \.self) { rating in
                    Button(action: {
                        feedback[exerciseId, default: ExerciseFeedback()].recovery = rating
                        recoveryAskedMuscles.insert(muscleGroup)
                        showRecoveryFor = nil
                    }) {
                        VStack(spacing: 2) {
                            Text(rating.emoji).font(.title2)
                            Text(rating.label).font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func effortPrompt(exerciseId: Int) -> some View {
        VStack(spacing: 8) {
            Text("How hard was that?")
                .font(.caption.bold())

            // RIR
            Text("Reps in Reserve (RIR)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([0, 1, 2, 3, 4, 5], id: \.self) { rir in
                    Button("\(rir == 5 ? "5+" : "\(rir)")") {
                        feedback[exerciseId, default: ExerciseFeedback()].rir = rir
                    }
                    .buttonStyle(.bordered)
                    .tint(feedback[exerciseId]?.rir == rir ? .blue : .gray)
                    .controlSize(.small)
                }
            }

            // Pump
            Text("Pump")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(PumpRating.allCases, id: \.self) { pump in
                    Button(action: {
                        feedback[exerciseId, default: ExerciseFeedback()].pump = pump
                    }) {
                        VStack(spacing: 1) {
                            Text(pump.emoji).font(.body)
                            Text(pump.rawValue).font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(feedback[exerciseId]?.pump == pump ? .purple : .gray)
                    .controlSize(.small)
                }
            }

            // Submit
            Button("Submit") {
                feedback[exerciseId, default: ExerciseFeedback()].submitted = true
                showEffortFor = nil
            }
            .buttonStyle(.borderedProminent)
            .disabled(feedback[exerciseId]?.rir == nil)
        }
        .padding()
        .background(.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func feedbackBadge(_ fb: ExerciseFeedback) -> some View {
        HStack(spacing: 8) {
            if let r = fb.recovery { Text("\(r.emoji) \(r.label)").font(.caption2) }
            if let rir = fb.rir { Text("RIR \(rir)").font(.caption2.bold()) }
            if let p = fb.pump { Text("\(p.emoji)").font(.caption2) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.secondary.opacity(0.1))
        .clipShape(Capsule())
    }

    // MARK: - Helpers

    private func canComplete(set: UISet, exercise: UIExercise) -> Bool {
        // Bilateral: need at least 1 rep
        return (set.reps ?? 0) > 0
    }

    private func fromKg(_ kg: Double) -> Double {
        if weightUnit == "kg" { return (kg * 2).rounded() / 2 }
        return (kg * kgToLbs / 5).rounded() * 5
    }

    private func toKg(_ value: Double) -> Double {
        if weightUnit == "kg" { return value }
        return value * lbsToKg
    }

    private func roundWeight(_ w: Double) -> Double {
        let inc: Double = weightUnit == "kg" ? 2.5 : 5.0
        return (w / inc).rounded() * inc
    }

    private func repDrop(_ baseReps: Int) -> Int {
        if baseReps >= 17 { return 3 }
        if baseReps >= 10 { return 2 }
        return 1
    }

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Actions

    private func startWorkout() async {
        do {
            // Check for existing in-progress session
            let existingSessions: [WorkoutSession] = try await APIClient.shared.get(
                "/sessions/", query: [.init(name: "limit", value: "5")]
            )
            let inProgress = existingSessions.first { $0.status == "in_progress" }

            let response: WorkoutSession
            if let existing = inProgress {
                response = try await APIClient.shared.get("/sessions/\(existing.id)")
            } else if let pid = planId {
                do {
                    response = try await APIClient.shared.post(
                        "/sessions/from-plan/\(pid)",
                        body: nil as String?,
                        queryItems: [
                            .init(name: "day_number", value: "\(dayNumber)"),
                            .init(name: "overload_style", value: "rep"),
                        ]
                    )
                } catch APIError.httpError(409, let body) {
                    if let data = body?.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let detail = json["detail"] as? [String: Any],
                       let sid = detail["session_id"] as? Int {
                        response = try await APIClient.shared.get("/sessions/\(sid)")
                    } else {
                        throw APIError.httpError(409, body)
                    }
                }
            } else {
                // Free session — no plan
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                struct CreateBody: Encodable {
                    let date: String
                    let name: String
                }
                let draft: WorkoutSession = try await APIClient.shared.post(
                    "/sessions/",
                    body: CreateBody(
                        date: df.string(from: Date()),
                        name: planName
                    )
                )
                response = try await APIClient.shared.post("/sessions/\(draft.id)/start")
            }

            sessionId = response.id

            // Load all exercises for picker + lookups
            allExercises = try await APIClient.shared.get("/exercises/")
            let lookup = Dictionary(uniqueKeysWithValues: allExercises.map { ($0.id, $0) })

            // Load exercise notes
            let notes: [String: [String: String]] = (try? await APIClient.shared.get("/exercises/notes/all")) ?? [:]

            // Group sets by exercise
            var exerciseMap: [Int: [ExerciseSet]] = [:]
            var exerciseOrder: [Int] = []
            for set in response.sets ?? [] {
                let eid = set.exercise_id ?? 0
                if exerciseMap[eid] == nil { exerciseOrder.append(eid) }
                exerciseMap[eid, default: []].append(set)
            }

            exercises = exerciseOrder.compactMap { exId in
                guard let sets = exerciseMap[exId], let ex = lookup[exId] else { return nil }
                return UIExercise(
                    id: exId,
                    name: ex.name,
                    muscleGroup: ex.muscle_group ?? "",
                    category: ex.category ?? "",
                    isUnilateral: ex.is_unilateral ?? false,
                    isAssisted: ex.is_assisted ?? false,
                    equipmentType: ex.equipment_type ?? "barbell",
                    sets: sets.enumerated().map { i, s in
                        let w = s.planned_weight_kg != nil ? fromKg(s.planned_weight_kg!) : nil
                        let r = s.planned_reps
                        let isUni = ex.is_unilateral ?? false
                        return UISet(
                            backendId: s.id,
                            setNumber: i + 1,
                            weight: s.actual_weight_kg != nil ? fromKg(s.actual_weight_kg!) : w,
                            reps: s.actual_reps ?? r,
                            repsLeft: isUni ? (s.reps_left ?? s.planned_reps_left ?? r) : nil,
                            repsRight: isUni ? (s.reps_right ?? s.planned_reps_right ?? r) : nil,
                            done: s.completed_at != nil,
                            skipped: s.skipped_at != nil,
                            setType: SetType(rawValue: s.set_type ?? "standard") ?? .standard,
                            exerciseId: exId,
                            initWeight: w,
                            initReps: r,
                            oneRM: (w != nil && r != nil && r! > 0) ? w! * (1 + Double(r!) / 30) : nil
                        )
                    },
                    note: notes[String(exId)]?["note"]
                )
            }

            loading = false
            startClock()
            requestNotificationPermission()
            checkAllDone()
        } catch {
            self.error = error.localizedDescription
            print("[Workout] Start error: \(error)")
            loading = false
        }
    }

    private func completeSet(exIdx: Int, sIdx: Int) async {
        guard let sessionId,
              exIdx < exercises.count,
              sIdx < exercises[exIdx].sets.count else { return }

        let set = exercises[exIdx].sets[sIdx]
        let exercise = exercises[exIdx]
        guard !set.done, !set.skipped, let backendId = set.backendId else { return }

        exercises[exIdx].sets[sIdx].saving = true

        let effectiveReps = exercise.isUnilateral
            ? min(set.repsLeft ?? 0, set.repsRight ?? 0)
            : (set.reps ?? 0)
        let weightKg = toKg(set.weight ?? 0)

        do {
            let _: ExerciseSet = try await APIClient.shared.patch(
                "/sessions/\(sessionId)/sets/\(backendId)",
                body: UpdateSetRequest(
                    actual_reps: effectiveReps,
                    actual_weight_kg: weightKg,
                    completed_at: ISO8601DateFormatter().string(from: Date()),
                    reps_left: exercise.isUnilateral ? set.repsLeft : nil,
                    reps_right: exercise.isUnilateral ? set.repsRight : nil,
                    notes: nil,
                    set_type: set.setType.rawValue != "standard" ? set.setType.rawValue : nil,
                    sub_sets: nil,
                    draft_weight_kg: nil, draft_reps: nil
                )
            )

            exercises[exIdx].sets[sIdx].done = true
            exercises[exIdx].sets[sIdx].saving = false

            // Rep drop-off for remaining sets
            propagateDropOff(exIdx: exIdx, fromSet: sIdx)

            // Myo-rep match sync
            syncMyoMatch(exIdx: exIdx)

            // PR check
            checkForPR(exercise: exercise, set: set, effectiveReps: effectiveReps)

            // Start rest timer
            let duration = currentRestDurations.duration(for: exercise)
            startRest(seconds: duration)

            // Autoregulation: recovery prompt (first set of new muscle group)
            if !recoveryAskedMuscles.contains(exercise.muscleGroup) {
                let doneSetsForMuscle = exercises
                    .filter { $0.muscleGroup == exercise.muscleGroup }
                    .flatMap(\.sets)
                    .filter(\.done).count
                if doneSetsForMuscle == 1 { // just completed the first
                    showRecoveryFor = exercise.id
                }
            }

            // Autoregulation: effort prompt (all sets of this exercise done)
            let allExSetsDone = exercises[exIdx].sets.allSatisfy { $0.done || $0.skipped }
            if allExSetsDone && feedback[exercise.id]?.submitted != true {
                showEffortFor = exercise.id
            }

            checkAllDone()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            print("[Workout] Set complete error: \(error)")
            exercises[exIdx].sets[sIdx].saving = false
        }
    }

    /// Per-side completion for unilateral exercises.
    /// When both sides are done, automatically calls completeSet().
    private func completeSide(exIdx: Int, sIdx: Int, isLeft: Bool) async {
        guard exIdx < exercises.count, sIdx < exercises[exIdx].sets.count else { return }
        guard !exercises[exIdx].sets[sIdx].done else { return }

        if isLeft { exercises[exIdx].sets[sIdx].doneLeft  = true }
        else      { exercises[exIdx].sets[sIdx].doneRight = true }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Start rest timer after first side
        let exercise = exercises[exIdx]
        let duration = currentRestDurations.duration(for: exercise)
        startRest(seconds: duration)

        // When both sides are done, persist the set
        if exercises[exIdx].sets[sIdx].doneLeft && exercises[exIdx].sets[sIdx].doneRight {
            await completeSet(exIdx: exIdx, sIdx: sIdx)
        }
    }

    private func skipSet(exIdx: Int, sIdx: Int) {
        exercises[exIdx].sets[sIdx].skipped = true
        checkAllDone()
    }

    private func unskipSet(exIdx: Int, sIdx: Int) {
        exercises[exIdx].sets[sIdx].skipped = false
        checkAllDone()
    }

    private func undoSet(exIdx: Int, sIdx: Int) {
        exercises[exIdx].sets[sIdx].done = false
        exercises[exIdx].sets[sIdx].doneLeft = false
        exercises[exIdx].sets[sIdx].doneRight = false
        checkAllDone()
    }

    private func propagateDropOff(exIdx: Int, fromSet sIdx: Int) {
        let set = exercises[exIdx].sets[sIdx]
        let reps = set.reps ?? 0
        let weight = set.weight ?? 0
        guard reps > 0, weight > 0 else { return }

        for i in (sIdx + 1)..<exercises[exIdx].sets.count {
            guard !exercises[exIdx].sets[i].done, !exercises[exIdx].sets[i].skipped,
                  exercises[exIdx].sets[i].setType != .warmup else { continue }

            let setsAhead = i - sIdx
            let drop = repDrop(reps)
            let naturalReps = reps - (drop * setsAhead)

            if naturalReps >= 5 {
                // Normal drop — same weight, fewer reps
                exercises[exIdx].sets[i].weight = weight
                exercises[exIdx].sets[i].reps = naturalReps
            } else if naturalReps >= 1 {
                // Below floor — keep natural reps, same weight
                exercises[exIdx].sets[i].weight = weight
                exercises[exIdx].sets[i].reps = max(naturalReps, 1)
            } else {
                // Would be 0 or negative reps — reduce weight by 10%, reset to base reps
                exercises[exIdx].sets[i].weight = roundWeight(weight * 0.9)
                exercises[exIdx].sets[i].reps = reps
            }
        }
    }

    private func syncMyoMatch(exIdx: Int) {
        guard let set1 = exercises[exIdx].sets.first, set1.done else { return }
        for i in 1..<exercises[exIdx].sets.count {
            if exercises[exIdx].sets[i].setType == .myoRepMatch {
                exercises[exIdx].sets[i].weight = set1.weight
                exercises[exIdx].sets[i].reps = set1.reps
            }
        }
    }

    private func checkForPR(exercise: UIExercise, set: UISet, effectiveReps: Int) {
        guard let initW = set.initWeight, let initR = set.initReps else { return }
        let w = set.weight ?? 0
        let isAssist = exercise.isAssisted

        var prType = ""
        var prValue = ""
        if !isAssist && w > initW {
            prType = "weight"
            prValue = "\(Int(w)) \(weightUnit)"
        } else if effectiveReps > initR {
            prType = "reps"
            prValue = "\(effectiveReps) reps"
        }

        if !prType.isEmpty {
            let pr = PR(exerciseName: exercise.name, type: prType, value: prValue)
            withAnimation(.spring(duration: 0.3)) { prCelebration = pr }
            showConfetti = true
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { prCelebration = nil }
                showConfetti = false
            }
        }
    }

    private func addExercise(_ exercise: Exercise, setCount: Int) {
        if let target = swapTarget, let idx = exercises.firstIndex(where: { $0.id == target.id }) {
            // Swap mode
            exercises[idx] = UIExercise(
                id: exercise.id,
                name: exercise.name,
                muscleGroup: exercise.muscle_group ?? "",
                category: exercise.category ?? "",
                isUnilateral: exercise.is_unilateral ?? false,
                isAssisted: exercise.is_assisted ?? false,
                equipmentType: exercise.equipment_type ?? "barbell",
                sets: (1...setCount).map { n in
                    UISet(backendId: nil, setNumber: n, weight: nil, reps: nil,
                          done: false, skipped: false, setType: .standard, exerciseId: exercise.id)
                }
            )
            swapTarget = nil
        } else {
            // Add mode
            exercises.append(UIExercise(
                id: exercise.id,
                name: exercise.name,
                muscleGroup: exercise.muscle_group ?? "",
                category: exercise.category ?? "",
                isUnilateral: exercise.is_unilateral ?? false,
                isAssisted: exercise.is_assisted ?? false,
                equipmentType: exercise.equipment_type ?? "barbell",
                sets: (1...setCount).map { n in
                    UISet(backendId: nil, setNumber: n, weight: nil, reps: nil,
                          done: false, skipped: false, setType: .standard, exerciseId: exercise.id)
                }
            ))
        }
    }

    private func removeExercise(_ exIdx: Int) {
        exercises.remove(at: exIdx)
        checkAllDone()
    }

    private func moveExercise(from idx: Int, direction: Int) {
        let newIdx = idx + direction
        guard newIdx >= 0, newIdx < exercises.count else { return }
        exercises.swapAt(idx, newIdx)
    }

    private func addSet(exIdx: Int) {
        let n = exercises[exIdx].sets.count + 1
        exercises[exIdx].sets.append(
            UISet(backendId: nil, setNumber: n, weight: nil, reps: nil,
                  done: false, skipped: false, setType: .standard,
                  exerciseId: exercises[exIdx].id)
        )
    }

    private func removeLastSet(exIdx: Int) {
        guard let last = exercises[exIdx].sets.last, !last.done else { return }
        exercises[exIdx].sets.removeLast()
    }

    private func generateWarmups(exIdx: Int) {
        guard let workingWeight = exercises[exIdx].sets.first(where: { $0.setType != .warmup })?.weight,
              workingWeight > 0 else { return }

        let bar = settingsBarWeight(for: exercises[exIdx])
        let warmups: [(Double, Int)] = [
            (bar, 10),                                    // empty bar
            (roundWeight(workingWeight * 0.5), 8),        // 50%
            (roundWeight(workingWeight * 0.7), 5),        // 70%
            (roundWeight(workingWeight * 0.85), 3),       // 85%
        ].filter { $0.0 >= bar && $0.0 < workingWeight }

        let warmupSets = warmups.enumerated().map { pair -> UISet in
            let i = pair.offset
            let w = pair.element.0
            let r = pair.element.1
            return UISet(backendId: nil, setNumber: i + 1, weight: w, reps: r,
                  done: false, skipped: false, setType: .warmup,
                  exerciseId: exercises[exIdx].id)
        }

        // Renumber working sets
        let workingSets = exercises[exIdx].sets.filter { $0.setType != .warmup }
            .enumerated().map { pair -> UISet in
                let i = pair.offset
                let s = pair.element
                return UISet(backendId: s.backendId, setNumber: warmupSets.count + i + 1,
                           weight: s.weight, reps: s.reps, done: s.done, skipped: s.skipped,
                           setType: s.setType, exerciseId: s.exerciseId,
                           initWeight: s.initWeight, initReps: s.initReps, oneRM: s.oneRM)
            }

        exercises[exIdx].sets = warmupSets + workingSets
    }

    private func finishWorkout() {
        guard let sessionId else { return }
        finishing = true
        Task {
            do {
                let _: WorkoutSession = try await APIClient.shared.post(
                    "/sessions/\(sessionId)/complete"
                )

                // Detect PRs for summary
                endOfWorkoutPRs = detectPRs()

                // Write to HealthKit
                writeWorkoutToHealthKit()

                stopTimers()
                finished = true
                finishing = false
            } catch {
                print("[Workout] Finish error: \(error)")
                finishing = false
            }
        }
    }

    private func cancelWorkout() async {
        guard let sessionId else { dismiss(); return }
        do {
            try await APIClient.shared.delete("/sessions/\(sessionId)")
        } catch {
            print("[Workout] Cancel error: \(error)")
        }
        stopTimers()
        dismiss()
    }

    private func detectPRs() -> [PR] {
        var results: [PR] = []
        for ex in exercises {
            let isAssist = ex.isAssisted
            for set in ex.sets where set.done {
                guard let initW = set.initWeight, let initR = set.initReps else { continue }
                let w = set.weight ?? 0
                let r = set.reps ?? 0
                if !isAssist && w > initW {
                    results.append(PR(exerciseName: ex.name, type: "weight", value: "\(Int(w)) \(weightUnit)"))
                    break
                }
                if r > initR {
                    results.append(PR(exerciseName: ex.name, type: "reps", value: "\(r) reps"))
                    break
                }
            }
        }
        return results
    }

    // MARK: - Timers

    private func startClock() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if !clockPaused { elapsed += 1 }
        }
    }

    private func startRest(seconds: Int) {
        restSecs = seconds
        restActive = true
        restEndTime = Date().addingTimeInterval(TimeInterval(seconds))
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if let end = restEndTime {
                let remaining = Int(end.timeIntervalSinceNow)
                restSecs = max(0, remaining)
                if remaining <= 0 {
                    restTimer?.invalidate()
                    restActive = false
                    playChime()
                    sendRestCompleteNotification()
                }
            }
        }
    }

    private func adjustRest(_ delta: Int) {
        restSecs = max(0, restSecs + delta)
        restEndTime = Date().addingTimeInterval(TimeInterval(restSecs))
    }

    private func skipRest() {
        restTimer?.invalidate()
        restActive = false
    }

    private func stopTimers() {
        clockTimer?.invalidate()
        restTimer?.invalidate()
    }

    private func playChime() {
        AudioServicesPlaySystemSound(1007)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    private func checkAllDone() {
        allDone = !exercises.isEmpty && exercises.allSatisfy { ex in
            ex.sets.allSatisfy { $0.done || $0.skipped }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendRestCompleteNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Rest Complete"
        content.body = "Time for your next set!"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "restComplete", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - HealthKit

    private func writeWorkoutToHealthKit() {
        // TODO: Direct HealthKit write (replaces Capacitor plugin)
        // This will be implemented in the Settings + HealthKit phase
    }
}
