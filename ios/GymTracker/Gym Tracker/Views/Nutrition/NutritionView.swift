import SwiftUI

struct NutritionView: View {
    @State private var summary: DailySummary?
    @State private var loading = true
    @State private var selectedDate = Date()
    @State private var showAddFood = false
    @State private var activePhase: DietPhase?

    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: selectedDate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DatePicker("", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .padding(.horizontal)
                        .onChange(of: selectedDate) { _, _ in Task { await loadDay() } }

                    if loading {
                        ProgressView().padding(.top, 40)
                    } else if let summary {
                        macroCard(summary)

                        if let phase = activePhase {
                            phaseBadge(phase)
                        }

                        if summary.entries.isEmpty {
                            Text("No food entries for this day")
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(summary.entries) { entry in
                                    foodRow(entry)
                                    Divider()
                                }
                            }
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Nutrition")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showAddFood = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .task { await loadDay(); await loadPhase() }
            .refreshable { await loadDay() }
            .sheet(isPresented: $showAddFood) {
                AddFoodView(date: dateString, onSave: { Task { await loadDay() } })
            }
        }
    }

    private func macroCard(_ summary: DailySummary) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                macroRing(label: "Cal", value: summary.calories,
                          goal: activePhase?.target_calories, color: .orange)
                macroRing(label: "Protein", value: summary.protein,
                          goal: activePhase?.target_protein, color: .red)
                macroRing(label: "Carbs", value: summary.carbs,
                          goal: activePhase?.target_carbs, color: .blue)
                macroRing(label: "Fat", value: summary.fat,
                          goal: activePhase?.target_fat, color: .yellow)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private func macroRing(label: String, value: Double, goal: Double?, color: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 4).frame(width: 50, height: 50)
                if let goal, goal > 0 {
                    Circle()
                        .trim(from: 0, to: min(value / goal, 1.0))
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 50, height: 50)
                        .rotationEffect(.degrees(-90))
                }
                Text("\(Int(value))").font(.caption.bold())
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func phaseBadge(_ phase: DietPhase) -> some View {
        let color: Color = phase.phase_type == "cut" ? .red : phase.phase_type == "bulk" ? .green : .blue
        return HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(phase.phase_type.capitalized).font(.caption.bold())
            Spacer()
            if let cal = phase.target_calories {
                Text("\(Int(cal)) cal target").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }

    private func foodRow(_ entry: NutritionEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline)
                HStack(spacing: 8) {
                    Text("\(Int(entry.calories ?? 0)) cal").font(.caption).foregroundStyle(.orange)
                    Text("\(Int(entry.protein ?? 0))p").font(.caption).foregroundStyle(.red)
                    Text("\(Int(entry.carbs ?? 0))c").font(.caption).foregroundStyle(.blue)
                    Text("\(Int(entry.fat ?? 0))f").font(.caption).foregroundStyle(.yellow)
                }
            }
            Spacer()
            Button(role: .destructive) { Task { await deleteEntry(entry.id) } } label: {
                Image(systemName: "trash").font(.caption).foregroundStyle(.red.opacity(0.6))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func loadDay() async {
        do {
            summary = try await APIClient.shared.get("/nutrition/summary",
                query: [.init(name: "date", value: dateString)])
        } catch { print("[Nutrition] Load: \(error)") }
        loading = false
    }

    private func loadPhase() async {
        activePhase = try? await APIClient.shared.get("/nutrition/phases/active")
    }

    private func deleteEntry(_ id: Int) async {
        try? await APIClient.shared.delete("/nutrition/entries/\(id)")
        await loadDay()
    }
}

// MARK: - Add Food

struct AddFoodView: View {
    let date: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var tab = 0
    @State private var searchQuery = ""
    @State private var searchResults: [FoodResult] = []
    @State private var searching = false
    @State private var manualName = ""
    @State private var manualCal: Double?
    @State private var manualProtein: Double?
    @State private var manualCarbs: Double?
    @State private var manualFat: Double?
    @State private var manualQty: Double = 100

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Search").tag(0)
                    Text("Manual").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if tab == 0 { searchTab } else { manualTab }
            }
            .navigationTitle("Add Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var searchTab: some View {
        VStack(spacing: 0) {
            TextField("Search foods...", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .onSubmit { Task { await search() } }

            if searching {
                ProgressView().padding(.top, 20)
            } else {
                List(searchResults) { r in
                    Button(action: { Task { await logFood(r) } }) {
                        VStack(alignment: .leading) {
                            Text(r.name).font(.subheadline)
                            Text("\(Int(r.calories ?? 0)) cal · \(Int(r.protein ?? 0))p · \(Int(r.carbs ?? 0))c · \(Int(r.fat ?? 0))f")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var manualTab: some View {
        Form {
            Section("Food") { TextField("Name", text: $manualName) }
            Section("Macros") {
                mField("Calories", $manualCal)
                mField("Protein (g)", $manualProtein)
                mField("Carbs (g)", $manualCarbs)
                mField("Fat (g)", $manualFat)
            }
            Section {
                Button("Add Entry") { Task { await logManual() } }
                    .disabled(manualName.isEmpty)
            }
        }
    }

    private func mField(_ label: String, _ val: Binding<Double?>) -> some View {
        HStack {
            Text(label); Spacer()
            TextField("0", value: val, format: .number).keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing).frame(width: 80)
        }
    }

    private func search() async {
        guard !searchQuery.isEmpty else { return }
        searching = true
        searchResults = (try? await APIClient.shared.get("/nutrition/search",
            query: [.init(name: "q", value: searchQuery)])) ?? []
        searching = false
    }

    private func logFood(_ food: FoodResult) async {
        struct E: Encodable { let name: String; let date: String; let quantity_g: Double
            let calories: Double; let protein: Double; let carbs: Double; let fat: Double }
        let _: NutritionEntry? = try? await APIClient.shared.post("/nutrition/entries/",
            body: E(name: food.name, date: date, quantity_g: 100,
                    calories: food.calories ?? 0, protein: food.protein ?? 0,
                    carbs: food.carbs ?? 0, fat: food.fat ?? 0))
        onSave(); dismiss()
    }

    private func logManual() async {
        struct E: Encodable { let name: String; let date: String; let quantity_g: Double
            let calories: Double; let protein: Double; let carbs: Double; let fat: Double }
        let _: NutritionEntry? = try? await APIClient.shared.post("/nutrition/entries/",
            body: E(name: manualName, date: date, quantity_g: manualQty,
                    calories: manualCal ?? 0, protein: manualProtein ?? 0,
                    carbs: manualCarbs ?? 0, fat: manualFat ?? 0))
        onSave(); dismiss()
    }
}

struct FoodResult: Codable, Identifiable {
    var id: String { "\(name)-\(brand ?? "")" }
    let name: String
    let brand: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}
