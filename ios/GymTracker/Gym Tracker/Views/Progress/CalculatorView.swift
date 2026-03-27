import SwiftUI

struct CalculatorView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @Environment(\.dismiss) private var dismiss

    @State private var weightInput: String = ""
    @State private var repsInput: String = ""

    // ── 1RM formulas ──────────────────────────────────────────────────────────
    private struct Formula: Identifiable {
        let id = UUID()
        let name: String
        let fn: (Double, Double) -> Double
    }

    private let formulas: [Formula] = [
        Formula(name: "Epley")    { w, r in r == 1 ? w : w * (1 + r / 30) },
        Formula(name: "Brzycki")  { w, r in r == 1 ? w : w * (36 / (37 - r)) },
        Formula(name: "Lombardi") { w, r in w * pow(r, 0.1) },
        Formula(name: "O'Conner") { w, r in w * (1 + r * 0.025) },
        Formula(name: "Wathan")   { w, r in r == 1 ? w : (100 * w) / (48.8 + 53.8 * exp(-0.075 * r)) },
    ]

    private var weight: Double? { Double(weightInput) }
    private var reps: Double? {
        guard let r = Double(repsInput), r >= 1, r <= 30 else { return nil }
        return r
    }

    private var formulaResults: [(name: String, value: Int)]? {
        guard let w = weight, let r = reps, w > 0 else { return nil }
        return formulas.map { f in
            (name: f.name, value: Int(f.fn(w, r).rounded()))
        }
    }

    private var average1RM: Int? {
        guard let results = formulaResults, !results.isEmpty else { return nil }
        return Int((Double(results.map(\.value).reduce(0, +)) / Double(results.count)).rounded())
    }

    private let percentages = [100, 95, 90, 85, 80, 75, 70, 65, 60, 55, 50]

    var body: some View {
        NavigationStack {
            Form {
                // ── Input ──────────────────────────────────────────────────
                Section("Lift") {
                    HStack {
                        Text("Weight (\(weightUnit))")
                        Spacer()
                        TextField("e.g. 225", text: $weightInput)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Reps performed")
                        Spacer()
                        TextField("1–30", text: $repsInput)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }

                // ── Formula results ────────────────────────────────────────
                if let results = formulaResults, let avg = average1RM {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Average Est. 1RM")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("\(avg) \(weightUnit)")
                                    .font(.title.bold())
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            Image(systemName: "trophy.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.yellow)
                        }
                        .padding(.vertical, 4)
                    }

                    Section("By Formula") {
                        ForEach(results, id: \.name) { r in
                            HStack {
                                Text(r.name)
                                Spacer()
                                Text("\(r.value) \(weightUnit)")
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(abs(r.value - avg) <= 2 ? .primary : .secondary)
                            }
                        }
                    }

                    // ── Percentage table ───────────────────────────────────
                    Section("% of Max (Epley)") {
                        HStack {
                            Text("%").frame(width: 40, alignment: .leading)
                                .font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Text("Weight").frame(width: 80, alignment: .trailing)
                                .font(.caption.bold()).foregroundStyle(.secondary)
                            Text("~Reps").frame(width: 60, alignment: .trailing)
                                .font(.caption.bold()).foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)

                        ForEach(percentages, id: \.self) { pct in
                            let pctWeight = Int((Double(avg) * Double(pct) / 100).rounded())
                            // Estimated reps from Epley: reps = 30 * (1RM/w - 1)
                            let estReps: Int = pct == 100 ? 1 : {
                                let ratio = Double(avg) / Double(pctWeight)
                                let r = max(1, Int((30 * (ratio - 1)).rounded()))
                                return min(r, 30)
                            }()

                            HStack {
                                Text("\(pct)%")
                                    .frame(width: 40, alignment: .leading)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(pctWeight) \(weightUnit)")
                                    .frame(width: 80, alignment: .trailing)
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(pct == 100 ? .primary : pct >= 85 ? .orange : .primary)
                                Text("~\(estReps)")
                                    .frame(width: 60, alignment: .trailing)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if weightInput.isEmpty && repsInput.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "function")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("Enter a weight and rep count to estimate your one-rep max across multiple formulas.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("1RM Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") {
                        weightInput = ""
                        repsInput = ""
                    }
                    .disabled(weightInput.isEmpty && repsInput.isEmpty)
                }
            }
        }
    }
}
