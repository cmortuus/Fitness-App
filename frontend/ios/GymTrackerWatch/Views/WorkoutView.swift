import SwiftUI

struct WorkoutView: View {
    let state: WorkoutState
    @EnvironmentObject var connectivity: WatchConnectivityManager

    var currentExercise: WatchExercise? {
        guard state.currentExerciseIndex < state.exercises.count else { return nil }
        return state.exercises[state.currentExerciseIndex]
    }

    var currentSet: WatchSet? {
        guard let ex = currentExercise,
              state.currentSetIndex < ex.sets.count else { return nil }
        return ex.sets[state.currentSetIndex]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Workout name + elapsed time
                HStack {
                    Text(state.workoutName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(formatTime(state.elapsed))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 4)

                // Rest timer
                if state.restActive {
                    RestTimerView(seconds: state.restSecs) {
                        connectivity.skipRest()
                    }
                } else if let exercise = currentExercise, let set = currentSet {
                    // Current exercise + set
                    SetView(
                        exercise: exercise,
                        set: set,
                        onComplete: {
                            connectivity.completeSet(
                                exerciseId: exercise.id,
                                setLocalId: set.id
                            )
                        },
                        onSkip: {
                            connectivity.skipSet(
                                exerciseId: exercise.id,
                                setLocalId: set.id
                            )
                        }
                    )
                } else {
                    // All exercises done
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.green)
                        Text("All sets done!")
                            .font(.headline)
                        Text("Finish on phone")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)
                }

                // Exercise list (compact)
                Divider()
                    .padding(.vertical, 4)

                ForEach(state.exercises) { exercise in
                    ExerciseRow(
                        exercise: exercise,
                        isCurrent: exercise.id == currentExercise?.id
                    )
                }
            }
            .padding(.horizontal, 4)
        }
    }

    func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Set View
struct SetView: View {
    let exercise: WatchExercise
    let set: WatchSet
    let onComplete: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(exercise.name)
                .font(.system(.body, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text("Set \(set.setNumber) of \(exercise.sets.count)")
                .font(.caption2)
                .foregroundColor(.secondary)

            // Weight + Reps
            HStack(spacing: 16) {
                VStack {
                    Text("\(Int(set.weight ?? 0))")
                        .font(.system(.title2, weight: .bold))
                    Text(set.unit)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack {
                    Text("\(set.reps ?? 0)")
                        .font(.system(.title2, weight: .bold))
                    Text("reps")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onSkip) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .tint(.gray)

                Button(action: onComplete) {
                    Image(systemName: "checkmark")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
    }
}

// MARK: - Rest Timer View
struct RestTimerView: View {
    let seconds: Int
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("REST")
                .font(.caption)
                .foregroundColor(.blue)
                .fontWeight(.semibold)

            Text(formatTime(seconds))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(seconds <= 10 ? .orange : .white)

            Button("Skip", action: onSkip)
                .buttonStyle(.bordered)
                .tint(.blue)
                .font(.caption)
        }
        .padding(.vertical, 12)
    }

    func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Exercise Row (compact list)
struct ExerciseRow: View {
    let exercise: WatchExercise
    let isCurrent: Bool

    var completedSets: Int {
        exercise.sets.filter { $0.done || $0.skipped }.count
    }

    var body: some View {
        HStack {
            if isCurrent {
                Circle()
                    .fill(.blue)
                    .frame(width: 6, height: 6)
            }

            Text(exercise.name)
                .font(.caption2)
                .foregroundColor(isCurrent ? .white : .secondary)
                .lineLimit(1)

            Spacer()

            Text("\(completedSets)/\(exercise.sets.count)")
                .font(.caption2)
                .foregroundColor(completedSets == exercise.sets.count ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }
}
