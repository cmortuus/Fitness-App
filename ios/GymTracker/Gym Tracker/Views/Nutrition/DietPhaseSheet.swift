import SwiftUI

struct DietPhaseSheet: View {
    let activePhase: DietPhase?
    let onUpdate: () -> Void

    @Environment(\.dismiss) var dismiss
    @State private var phaseType = "maintenance"
    @State private var durationWeeks: Double = 8
    @State private var targetRatePct: Double = 0.7
    @State private var activityMultiplier: Double = 1.4
    @State private var carbPreset = "moderate"
    @State private var bodyFatPct: String = ""
    @State private var proteinPerLb: Double = 1.0
    @State private var saving = false
    @State private var ending = false
    @State private var errorMessage: String?

    private let activityLevels: [(String, Double)] = [
        ("Sedentary (desk job)", 1.2),
        ("Lightly active", 1.375),
        ("Moderately active", 1.55),
        ("Very active", 1.725),
        ("Extremely active", 1.9),
    ]

    private let carbPresets: [(String, String)] = [
        ("Low carb", "low"),
        ("Moderate", "moderate"),
        ("High carb", "high"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if let phase = activePhase {
                    activePhaseView(phase)
                } else {
                    createPhaseView
                }
            }
            .navigationTitle("Diet Phase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Active Phase View

    private func activePhaseView(_ phase: DietPhase) -> some View {
        Group {
            Section("Current Phase") {
                HStack {
                    Circle()
                        .fill(phaseColor(phase.phase_type))
                        .frame(width: 10, height: 10)
                    Text(phase.phase_type.capitalized)
                        .font(.headline)
                    Spacer()
                    if let week = phase.current_week, let total = phase.duration_weeks {
                        Text("Week \(week)/\(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Since \(String(phase.started_on.prefix(10)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let goals = phase.current_goals {
                Section("Current Targets") {
                    if let cal = goals.calories { macroDisplay("Calories", Int(cal), "") }
                    if let p = goals.protein { macroDisplay("Protein", Int(p), "g") }
                    if let c = goals.carbs { macroDisplay("Carbs", Int(c), "g") }
                    if let f = goals.fat { macroDisplay("Fat", Int(f), "g") }
                }
            }

            if let suggestion = phase.suggestion, !suggestion.isEmpty {
                Section("Suggestion") {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let weightChange = phase.weight_change_kg {
                Section("Progress") {
                    let lbsChange = weightChange * 2.20462
                    HStack {
                        Text("Weight Change")
                        Spacer()
                        Text(String(format: "%+.1f lbs", lbsChange))
                            .foregroundStyle(lbsChange > 0 ? .green : lbsChange < 0 ? .red : .secondary)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await endPhase(phase.id) }
                } label: {
                    if ending {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("End Phase").frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - Create Phase View

    private var createPhaseView: some View {
        Group {
            Section("Phase Type") {
                Picker("Type", selection: $phaseType) {
                    Text("🔽 Cut").tag("cut")
                    Text("🔼 Bulk").tag("bulk")
                    Text("⚖️ Maintenance").tag("maintenance")
                }
                .pickerStyle(.segmented)
            }

            Section("Duration") {
                HStack {
                    Text("\(Int(durationWeeks)) weeks")
                    Spacer()
                    Stepper("", value: $durationWeeks, in: 4...24, step: 1)
                }
            }

            if phaseType != "maintenance" {
                Section("Target Rate") {
                    VStack(alignment: .leading) {
                        Text(phaseType == "cut"
                             ? "Loss rate: \(String(format: "%.1f", targetRatePct))% per week"
                             : "Gain rate: \(String(format: "%.1f", targetRatePct))% per week")
                        .font(.caption)
                        Slider(value: $targetRatePct, in: 0.3...1.5, step: 0.1)
                    }
                }
            }

            Section("Activity Level") {
                Picker("Activity", selection: $activityMultiplier) {
                    ForEach(activityLevels, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
            }

            Section("Carb Preference") {
                Picker("Carbs", selection: $carbPreset) {
                    ForEach(carbPresets, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Protein Target") {
                HStack {
                    Text(String(format: "%.1fg per lb", proteinPerLb))
                    Spacer()
                    Stepper("", value: $proteinPerLb, in: 0.5...1.5, step: 0.1)
                }
            }

            Section("Body Fat % (optional)") {
                TextField("e.g. 20", text: $bodyFatPct)
                    .keyboardType(.decimalPad)
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section {
                Button(action: { Task { await createPhase() } }) {
                    if saving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Start \(phaseType.capitalized) Phase")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(phaseColor(phaseType))
            }
        }
    }

    // MARK: - Helpers

    private func macroDisplay(_ label: String, _ value: Int, _ unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)\(unit)")
                .foregroundStyle(.secondary)
        }
    }

    private func phaseColor(_ type: String) -> Color {
        switch type {
        case "cut": return .red
        case "bulk": return .green
        default: return .blue
        }
    }

    // MARK: - Actions

    private func createPhase() async {
        saving = true
        errorMessage = nil

        struct CreateBody: Encodable {
            let phase_type: String
            let duration_weeks: Int
            let target_rate_pct: Double
            let activity_multiplier: Double
            let carb_preset: String
            let body_fat_pct: Double?
            let protein_per_lb: Double?
        }

        let bfPct = Double(bodyFatPct)

        do {
            let _: DietPhase = try await APIClient.shared.post(
                "/nutrition/phases/",
                body: CreateBody(
                    phase_type: phaseType,
                    duration_weeks: Int(durationWeeks),
                    target_rate_pct: targetRatePct,
                    activity_multiplier: activityMultiplier,
                    carb_preset: carbPreset,
                    body_fat_pct: bfPct,
                    protein_per_lb: proteinPerLb
                )
            )
            onUpdate()
            dismiss()
        } catch let APIError.httpError(code, body) {
            errorMessage = body ?? "Server error (\(code))"
            print("[Phase] Create error: \(code) \(body ?? "")")
        } catch {
            errorMessage = error.localizedDescription
            print("[Phase] Create error: \(error)")
        }
        saving = false
    }

    private func endPhase(_ id: Int) async {
        ending = true
        print("[Phase] Ending phase \(id) — DELETE /nutrition/phases/active/")
        do {
            try await APIClient.shared.delete("/nutrition/phases/active")
            print("[Phase] End success")
            onUpdate()
            dismiss()
        } catch let APIError.httpError(code, body) {
            print("[Phase] End HTTP error: \(code) \(body ?? "")")
        } catch {
            print("[Phase] End error: \(error)")
        }
        ending = false
    }
}
