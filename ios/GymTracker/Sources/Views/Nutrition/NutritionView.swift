import SwiftUI

struct NutritionView: View {
    @State private var summary: DailySummary?
    @State private var loading = true
    @State private var selectedDate = Date()

    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: selectedDate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Date picker
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .padding(.horizontal)
                        .onChange(of: selectedDate) { _, _ in
                            Task { await loadDay() }
                        }

                    if loading {
                        ProgressView()
                            .padding(.top, 40)
                    } else if let summary {
                        // Macro rings
                        MacroSummaryCard(summary: summary)

                        // Food entries
                        ForEach(summary.entries) { entry in
                            FoodEntryRow(entry: entry)
                        }

                        if summary.entries.isEmpty {
                            Text("No food entries for this day")
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Nutrition")
            .task { await loadDay() }
        }
    }

    private func loadDay() async {
        loading = true
        do {
            summary = try await APIClient.shared.get(
                "/nutrition/summary",
                query: [.init(name: "date", value: dateString)]
            )
        } catch {
            print("Nutrition load error: \(error)")
        }
        loading = false
    }
}

struct MacroSummaryCard: View {
    let summary: DailySummary

    var body: some View {
        HStack(spacing: 24) {
            MacroCircle(label: "Cal", value: summary.calories, color: .orange)
            MacroCircle(label: "Protein", value: summary.protein, color: .red)
            MacroCircle(label: "Carbs", value: summary.carbs, color: .blue)
            MacroCircle(label: "Fat", value: summary.fat, color: .yellow)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct MacroCircle: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(Int(value))")
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct FoodEntryRow: View {
    let entry: NutritionEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(entry.name)
                    .font(.subheadline)
                Text("\(Int(entry.calories ?? 0)) cal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(entry.protein ?? 0))p / \(Int(entry.carbs ?? 0))c / \(Int(entry.fat ?? 0))f")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
