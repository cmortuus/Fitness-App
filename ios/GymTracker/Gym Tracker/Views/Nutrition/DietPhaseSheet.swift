import SwiftUI

struct DietPhaseSheet: View {
    let activePhase: DietPhase?
    let onUpdate: () -> Void

    @Environment(\.dismiss) var dismiss
    @State private var phaseType = "maintenance"
    @State private var targetCalories: Double = 2000
    @State private var targetProtein: Double = 150
    @State private var targetCarbs: Double = 200
    @State private var targetFat: Double = 70
    @State private var bodyWeight: Double = 180 // lbs, for auto-calc
    @State private var saving = false
    @State private var ending = false

    // Auto-calculate macros based on phase type and body weight
    private var autoCalories: Double {
        let bwKg = bodyWeight * 0.453592
        switch phaseType {
        case "cut": return bwKg * 22 // ~10 cal/lb
        case "bulk": return bwKg * 33 // ~15 cal/lb
        default: return bwKg * 28 // ~12.5 cal/lb
        }
    }

    private var autoProtein: Double {
        bodyWeight * 1.0 // 1g per lb
    }

    var body: some View {
        NavigationStack {
            Form {
                if let phase = activePhase {
                    // Active phase info
                    Section("Current Phase") {
                        HStack {
                            Circle()
                                .fill(phaseColor(phase.phase_type))
                                .frame(width: 10, height: 10)
                            Text(phase.phase_type.capitalized)
                                .font(.headline)
                            Spacer()
                            Text("Since \(String(phase.start_date.prefix(10)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let cal = phase.target_calories {
                            HStack {
                                Text("Target Calories")
                                Spacer()
                                Text("\(Int(cal))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let p = phase.target_protein {
                            HStack {
                                Text("Target Protein")
                                Spacer()
                                Text("\(Int(p))g")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(role: .destructive) {
                            Task { await endPhase(phase.id) }
                        } label: {
                            if ending {
                                ProgressView()
                            } else {
                                Text("End Phase")
                            }
                        }
                    }
                } else {
                    // Create new phase
                    Section("New Diet Phase") {
                        Picker("Type", selection: $phaseType) {
                            Text("🔽 Cut").tag("cut")
                            Text("🔼 Bulk").tag("bulk")
                            Text("⚖️ Maintenance").tag("maintenance")
                        }
                    }

                    Section("Body Weight (for auto-calc)") {
                        HStack {
                            TextField("lbs", value: $bodyWeight, format: .number)
                                .keyboardType(.decimalPad)
                            Text("lbs")
                                .foregroundStyle(.secondary)
                        }

                        Button("Auto-Calculate Macros") {
                            targetCalories = autoCalories.rounded()
                            targetProtein = autoProtein.rounded()
                            let proteinCal = targetProtein * 4
                            let fatCal = targetCalories * 0.25
                            targetFat = (fatCal / 9).rounded()
                            targetCarbs = ((targetCalories - proteinCal - fatCal) / 4).rounded()
                        }
                        .font(.caption)
                    }

                    Section("Macro Targets") {
                        macroRow("Calories", $targetCalories, "")
                        macroRow("Protein", $targetProtein, "g")
                        macroRow("Carbs", $targetCarbs, "g")
                        macroRow("Fat", $targetFat, "g")

                        // Summary
                        let totalCal = targetProtein * 4 + targetCarbs * 4 + targetFat * 9
                        if abs(totalCal - targetCalories) > 50 {
                            Text("⚠️ Macros total \(Int(totalCal)) cal (target: \(Int(targetCalories)))")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section {
                        Button(action: { Task { await createPhase() } }) {
                            if saving {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
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
            .navigationTitle("Diet Phase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Helpers

    private func macroRow(_ label: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
            }
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
        struct CreatePhase: Encodable {
            let phase_type: String
            let target_calories: Double
            let target_protein: Double
            let target_carbs: Double
            let target_fat: Double
        }

        do {
            let _: DietPhase = try await APIClient.shared.post(
                "/nutrition/phases/",
                body: CreatePhase(
                    phase_type: phaseType,
                    target_calories: targetCalories,
                    target_protein: targetProtein,
                    target_carbs: targetCarbs,
                    target_fat: targetFat
                )
            )
            onUpdate()
            dismiss()
        } catch {
            print("[Phase] Create error: \(error)")
        }
        saving = false
    }

    private func endPhase(_ id: Int) async {
        ending = true
        do {
            let _: DietPhase = try await APIClient.shared.patch("/nutrition/phases/\(id)/end")
            onUpdate()
            dismiss()
        } catch {
            print("[Phase] End error: \(error)")
        }
        ending = false
    }
}
