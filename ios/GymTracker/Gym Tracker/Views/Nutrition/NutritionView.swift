import SwiftUI

struct NutritionView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @State private var summary: DailySummary?
    @State private var mealEntries: [String: [NutritionEntry]] = [:]
    @State private var loading = true
    @State private var selectedDate = Date()
    @State private var showAddFood = false
    @State private var activePhase: DietPhase?
    @State private var showPhaseSheet = false
    @State private var showScanner = false
    @State private var showLabelScanner = false
    @State private var pendingBarcode: String? = nil
    @State private var showAlcoholCalc = false
    @State private var showQuickAdd = false
    @State private var showRecipes = false
    @State private var showGoalsSheet = false
    @State private var waterSummary: WaterSummary?
    @State private var editingEntry: NutritionEntry? = nil
    @State private var showCopyDayConfirm = false
    @State private var barcodeFoodWrapper: IdentifiedFood? = nil

    private let meals = ["breakfast", "lunch", "dinner", "snack"]

    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: selectedDate)
    }

    private var allEntries: [NutritionEntry] {
        meals.flatMap { mealEntries[$0] ?? [] }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 16) {
                        // Date navigation
                        dateNav

                        if loading {
                            ProgressView().padding(.top, 60)
                        } else {
                            // Phase card
                            phaseCard

                            // Macro rings
                            macroRings

                            // Net calories banner
                            netCaloriesBanner

                            // Water tracker
                            waterCard

                            // Micronutrients (when data available)
                            micronutrients

                            // Food log
                            foodLog
                        }

                        Spacer(minLength: 80)
                    }
                }
                .background(Color(.systemGroupedBackground))

                // Floating add button
                HStack(spacing: 12) {
                    Button { showQuickAdd = true } label: {
                        Image(systemName: "bolt.fill")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Button { showRecipes = true } label: {
                        Image(systemName: "fork.knife")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Button { showAlcoholCalc = true } label: {
                        Text("🍺")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Button { showScanner = true } label: {
                        Image(systemName: "barcode.viewfinder")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Button { showAddFood = true } label: {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.blue)
                            .clipShape(Circle())
                            .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, 16)
            }
            .navigationTitle("Nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .task { await loadAll() }
            .refreshable { await loadAll() }
            .onChange(of: selectedDate) { _, _ in Task { await loadAll() } }
            .sheet(isPresented: $showAddFood) {
                AddFoodView(date: dateString, onSave: { Task { await loadAll() } })
            }
            .sheet(isPresented: $showPhaseSheet) {
                DietPhaseSheet(activePhase: activePhase, onUpdate: { Task { await loadPhase(); await loadAll() } })
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView { barcode in
                    showScanner = false
                    Task { await lookupBarcode(barcode) }
                }
            }
            .sheet(isPresented: $showLabelScanner) {
                NutritionLabelScanner(barcode: pendingBarcode) { scanned in
                    showLabelScanner = false
                    showAddFood = true
                }
            }
            .sheet(isPresented: $showAlcoholCalc) {
                AlcoholCalculatorView(date: dateString, onSave: { Task { await loadAll() } })
            }
            .sheet(isPresented: $showQuickAdd) {
                QuickAddView(date: dateString, onSave: { Task { await loadAll() } })
            }
            .sheet(isPresented: $showRecipes) {
                RecipesView(date: dateString, onLog: { Task { await loadAll() } })
            }
            .sheet(isPresented: $showGoalsSheet) {
                MacroGoalsSheet(currentGoals: summary?.goals, onSave: { Task { await loadAll() } })
            }
            .sheet(item: $editingEntry) { entry in
                EditEntrySheet(entry: entry, onSave: { Task { await loadAll() } }, onDelete: {
                    Task { await deleteEntry(entry.id); await loadAll() }
                })
            }
            .sheet(item: $barcodeFoodWrapper) { wrapper in
                FoodDetailSheet(food: wrapper.food, date: dateString, meal: "snack") {
                    Task { await loadAll() }
                }
            }
            .confirmationDialog(
                "Copy yesterday's food log to today?",
                isPresented: $showCopyDayConfirm,
                titleVisibility: .visible
            ) {
                Button("Copy") { Task { await copyPreviousDay() } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Date Navigation

    private var dateNav: some View {
        HStack {
            Button { shiftDate(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            VStack(spacing: 2) {
                Text(Calendar.current.isDateInToday(selectedDate) ? "Today" : selectedDate.formatted(.dateTime.weekday(.wide)))
                    .font(.subheadline.weight(.semibold))
                Text(selectedDate.formatted(.dateTime.month().day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { shiftDate(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Calendar.current.isDateInToday(selectedDate) ? .tertiary : .primary)
            }
            .disabled(Calendar.current.isDateInToday(selectedDate))
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private func shiftDate(_ days: Int) {
        if let new = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            loading = true
            selectedDate = new
        }
    }

    // MARK: - Phase Card

    private var phaseCard: some View {
        Group {
            if let phase = activePhase {
                VStack(spacing: 10) {
                    HStack {
                        HStack(spacing: 6) {
                            Text(phaseIcon(phase.phase_type))
                            Text(phase.phase_type.capitalized)
                                .font(.headline)
                            Text("Week \(phase.current_week ?? 1) of \(phase.duration_weeks ?? 12)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("End") {
                            Task { await endPhase(phase.id) }
                        }
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.7))
                    }

                    // Progress bar
                    let progress = Double(phase.current_week ?? 1) / Double(phase.duration_weeks ?? 12)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.06)).frame(height: 6)
                            Capsule().fill(phaseColor(phase.phase_type))
                                .frame(width: geo.size.width * min(progress, 1.0), height: 6)
                        }
                    }
                    .frame(height: 6)

                    // Weight range
                    if let start = phase.starting_weight_kg, let target = phase.target_weight_kg {
                        let dispStart  = weightUnit == "lbs" ? start  * 2.20462 : start
                        let dispTarget = weightUnit == "lbs" ? target * 2.20462 : target
                        HStack {
                            Text(String(format: "%.1f %@", dispStart, weightUnit))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if let current = phase.current_weight_kg {
                                let dispCurrent = weightUnit == "lbs" ? current * 2.20462 : current
                                Text(String(format: "%.1f %@", dispCurrent, weightUnit))
                                    .font(.caption2.weight(.semibold))
                            }
                            Spacer()
                            Text(String(format: "%.1f %@", dispTarget, weightUnit))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            } else {
                Button { showPhaseSheet = true } label: {
                    VStack(spacing: 6) {
                        Text("No active diet phase")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Start a Cut, Bulk, or Maintenance")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Macro Rings

    private var macroRings: some View {
        let totals = summary?.totals ?? MacroTotals(calories: 0, protein: 0, carbs: 0, fat: 0)
        // Use explicit goals, or fall back to active phase targets
        let goals = summary?.goals ?? {
            guard let phase = activePhase, let pg = phase.current_goals else { return nil }
            return MacroGoals(calories: pg.calories, protein: pg.protein, carbs: pg.carbs, fat: pg.fat)
        }()

        return VStack(spacing: 16) {
            if goals != nil {
                HStack(alignment: .top, spacing: 0) {
                    // Big calorie ring
                    ringView(
                        value: totals.calories,
                        goal: goals?.calories ?? 2000,
                        label: "Calories",
                        unit: "",
                        color: .blue,
                        size: 130
                    )
                    .frame(maxWidth: .infinity)

                    // Smaller macro rings
                    VStack(spacing: 12) {
                        ringView(
                            value: totals.protein,
                            goal: goals?.protein ?? 150,
                            label: "Protein",
                            unit: "g",
                            color: .purple,
                            size: 70
                        )
                        HStack(spacing: 16) {
                            ringView(
                                value: totals.carbs,
                                goal: goals?.carbs ?? 200,
                                label: "Carbs",
                                unit: "g",
                                color: .orange,
                                size: 55
                            )
                            ringView(
                                value: totals.fat,
                                goal: goals?.fat ?? 65,
                                label: "Fat",
                                unit: "g",
                                color: .yellow,
                                size: 55
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                // No goals — simple totals + set goals prompt
                VStack(spacing: 12) {
                    HStack(spacing: 20) {
                        simpleMacro("Cal", totals.calories, .orange)
                        simpleMacro("P", totals.protein, .red)
                        simpleMacro("C", totals.carbs, .blue)
                        simpleMacro("F", totals.fat, .yellow)
                    }
                    Button { showGoalsSheet = true } label: {
                        Label("Set Macro Goals", systemImage: "target")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Edit goals button (shown when goals are set)
            if goals != nil {
                Button { showGoalsSheet = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func ringView(value: Double, goal: Double, label: String, unit: String, color: Color, size: CGFloat) -> some View {
        let progress = goal > 0 ? min(value / goal, 1.0) : 0

        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: size > 80 ? 10 : 6)
                    .frame(width: size, height: size)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(value > goal ? Color.red : color, style: StrokeStyle(lineWidth: size > 80 ? 10 : 6, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: progress)

                VStack(spacing: 1) {
                    Text("\(Int(value))\(unit)")
                        .font(size > 80 ? .title3.weight(.bold).monospacedDigit() : .caption.weight(.bold).monospacedDigit())
                    Text("/ \(Int(goal))\(unit)")
                        .font(size > 80 ? .caption2 : .system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func simpleMacro(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(Int(value))")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Net Calories Banner

    @ViewBuilder
    private var netCaloriesBanner: some View {
        if let remaining = summary?.remaining, let goalCal = summary?.goals?.calories, goalCal > 0 {
            let rem = remaining.calories ?? 0
            let isOver = rem < 0
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOver ? "Over budget" : "Remaining today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(abs(Int(rem))) kcal")
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(isOver ? .red : .green)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Goal").font(.caption2).foregroundStyle(.secondary)
                        Text("\(Int(goalCal))").font(.caption2.weight(.semibold))
                    }
                    HStack(spacing: 4) {
                        Text("Eaten").font(.caption2).foregroundStyle(.secondary)
                        Text("\(Int(summary?.totals.calories ?? 0))").font(.caption2.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isOver ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
        }
    }

    // MARK: - Water Card

    @ViewBuilder
    private var waterCard: some View {
        if let water = waterSummary {
            WaterTrackerCard(
                summary: water,
                date: dateString,
                onLog: { Task { await loadWater() } }
            )
            .padding(.horizontal)
        }
    }

    // MARK: - Micronutrients

    private struct MicroItem {
        let key: String
        let name: String
        let unit: String
        let color: Color
    }

    private let microItems: [MicroItem] = [
        MicroItem(key: "fiber_g",        name: "Fiber",       unit: "g",   color: .green),
        MicroItem(key: "sugar_g",        name: "Sugar",       unit: "g",   color: .orange),
        MicroItem(key: "sodium_mg",      name: "Sodium",      unit: "mg",  color: .red),
        MicroItem(key: "cholesterol_mg", name: "Cholesterol", unit: "mg",  color: .yellow),
        MicroItem(key: "calcium_mg",     name: "Calcium",     unit: "mg",  color: .blue),
        MicroItem(key: "iron_mg",        name: "Iron",        unit: "mg",  color: Color.brown),
        MicroItem(key: "potassium_mg",   name: "Potassium",   unit: "mg",  color: .purple),
        MicroItem(key: "magnesium_mg",   name: "Magnesium",   unit: "mg",  color: .teal),
        MicroItem(key: "vitamin_c_mg",   name: "Vitamin C",   unit: "mg",  color: .orange),
        MicroItem(key: "vitamin_d_mcg",  name: "Vitamin D",   unit: "mcg", color: .yellow),
        MicroItem(key: "vitamin_b12_mcg",name: "B12",         unit: "mcg", color: .cyan),
        MicroItem(key: "omega3_g",       name: "Omega-3",     unit: "g",   color: .blue),
    ]

    @ViewBuilder
    private var micronutrients: some View {
        if let micros = summary?.micronutrient_totals, !micros.isEmpty {
            let present = microItems.filter { micros[$0.key] != nil }
            if !present.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Micronutrients")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(present, id: \.key) { item in
                            if let val = micros[item.key] {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(item.color.opacity(0.25))
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text("\(formatMicro(val)) \(item.unit)")
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            }
        }
    }

    private func formatMicro(_ val: Double) -> String {
        if val >= 100 { return String(format: "%.0f", val) }
        if val >= 10  { return String(format: "%.1f", val) }
        return String(format: "%.2f", val)
    }

    // MARK: - Food Log

    private var foodLog: some View {
        VStack(spacing: 0) {
            if allEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("No food logged today")
                        .font(.subheadline.bold())
                    Text("Tap + to log a meal or copy yesterday's log.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button {
                            showAddFood = true
                        } label: {
                            Label("Add Food", systemImage: "plus.circle.fill")
                                .font(.subheadline.bold())
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if Calendar.current.isDateInToday(selectedDate) || Calendar.current.isDate(selectedDate, inSameDayAs: Date()) {
                            Button {
                                showCopyDayConfirm = true
                            } label: {
                                Label("Copy Yesterday", systemImage: "doc.on.doc")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            } else {
                let orderedMeals = ["breakfast", "lunch", "dinner", "snack"]
                let presentMeals = orderedMeals.filter { !(mealEntries[$0]?.isEmpty ?? true) }
                let otherMeals = mealEntries.keys.filter { !orderedMeals.contains($0) }.sorted()

                VStack(spacing: 10) {
                    ForEach(presentMeals + otherMeals, id: \.self) { meal in
                        if let entries = mealEntries[meal], !entries.isEmpty {
                            mealSection(meal: meal, entries: entries)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func mealSection(meal: String, entries: [NutritionEntry]) -> some View {
        let mealCalories = entries.compactMap(\.calories).reduce(0, +)
        let mealIcon: String
        switch meal {
        case "breakfast": mealIcon = "sun.horizon.fill"
        case "lunch":     mealIcon = "sun.max.fill"
        case "dinner":    mealIcon = "moon.fill"
        default:          mealIcon = "fork.knife"
        }

        return VStack(spacing: 0) {
            // Meal header
            HStack(spacing: 6) {
                Image(systemName: mealIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(meal.capitalized)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(mealCalories)) kcal")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Entries
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    foodRow(entry)
                    if entry.id != entries.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func foodRow(_ entry: NutritionEntry) -> some View {
        Button {
            editingEntry = entry
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        if let cal = entry.calories {
                            Text("\(Int(cal)) kcal")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                        }
                        if let p = entry.protein, p > 0 {
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                            Text("P \(Int(p))g").foregroundStyle(.blue)
                        }
                        if let c = entry.carbs, c > 0 {
                            Text("C \(Int(c))g").foregroundStyle(.green)
                        }
                        if let f = entry.fat, f > 0 {
                            Text("F \(Int(f))g").foregroundStyle(.yellow)
                        }
                        if let q = entry.quantity_g, q > 0 {
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                            Text("\(Int(q))g").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                }
                Spacer()
                Image(systemName: "pencil.circle")
                    .font(.body)
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func phaseIcon(_ type: String) -> String {
        switch type {
        case "cut": return "🔽"
        case "bulk": return "🔼"
        default: return "⚖️"
        }
    }

    private func phaseColor(_ type: String) -> Color {
        switch type {
        case "cut": return .red
        case "bulk": return .green
        default: return .blue
        }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadDay() }
            group.addTask { await self.loadWater() }
        }
        loading = false
    }

    private func loadDay() async {
        do {
            summary = try await APIClient.shared.get("/nutrition/summary",
                query: [.init(name: "date", value: dateString)])
        } catch { print("[Nutrition] Summary: \(error)") }
        do {
            let response: EntriesResponse = try await APIClient.shared.get("/nutrition/entries",
                query: [.init(name: "date", value: dateString)])
            mealEntries = response.meals
        } catch { print("[Nutrition] Entries: \(error)") }
    }

    private func loadWater() async {
        waterSummary = try? await APIClient.shared.get("/nutrition/water",
            query: [.init(name: "date", value: dateString)])
    }

    private func loadPhase() async {
        activePhase = try? await APIClient.shared.get("/nutrition/phases/active")
    }

    private func deleteEntry(_ id: Int) async {
        try? await APIClient.shared.delete("/nutrition/entries/\(id)")
    }

    private func copyPreviousDay() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let fromDate = df.string(from: yesterday)
        do {
            struct CopyResult: Decodable { let copied: Int }
            let _: CopyResult = try await APIClient.shared.post(
                "/nutrition/entries/copy-day",
                queryItems: [.init(name: "from_date", value: fromDate), .init(name: "to_date", value: dateString)]
            )
        } catch { print("[Nutrition] CopyDay: \(error)") }
        await loadDay()
    }

    private func endPhase(_ id: Int) async {
        do {
            guard let token = await AuthService.shared.accessToken else { return }
            var req = URLRequest(url: URL(string: "https://lethal.dev/api/nutrition/phases/active")!)
            req.httpMethod = "DELETE"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as! HTTPURLResponse).statusCode
            print("[Phase] End status: \(code)")
            if code == 204 || (200...299).contains(code) {
                activePhase = nil
                await loadDay()
            } else {
                print("[Phase] End failed: \(code)")
            }
        } catch { print("[Phase] End error: \(error)") }
    }

    private func lookupBarcode(_ barcode: String) async {
        do {
            let food: FoodSearchResult = try await APIClient.shared.get("/nutrition/barcode/\(barcode)")
            barcodeFoodWrapper = IdentifiedFood(food: food)
        } catch {
            pendingBarcode = barcode
            showLabelScanner = true
        }
    }
}

// MARK: - Response Models

private struct EntriesResponse: Codable {
    let date: String
    let meals: [String: [NutritionEntry]]
}

struct IdentifiedFood: Identifiable {
    let id = UUID()
    let food: FoodSearchResult
}

private struct NutritionEntryBody: Encodable {
    var food_item_id: Int? = nil
    let name: String
    let date: String
    var meal: String = "snack"
    let quantity_g: Double
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    var category: String? = nil
}

struct FoodSearchResult: Codable {
    let id: Int?
    let name: String
    let brand: String?
    let calories_per_100g: Double?
    let protein_per_100g: Double?
    let carbs_per_100g: Double?
    let fat_per_100g: Double?
    let serving_size_g: Double?
    let serving_label: String?
    let micronutrients: [String: Double]?
}

// MARK: - Add Food View

struct AddFoodView: View {
    let date: String
    let onSave: () -> Void
    var defaultMeal: String = "snack"
    @Environment(\.dismiss) var dismiss

    enum Tab { case search, recent, saved, manual }
    @State private var activeTab: Tab = .search

    @State private var searchQuery = ""
    @State private var searchResults: [FoodSearchResult] = []
    @State private var searching = false
    @State private var showScanner = false
    @State private var showLabelScanner = false
    @State private var pendingBarcode: String? = nil
    @State private var selectedFoodWrapper: IdentifiedFood? = nil
    @State private var selectedMeal: String

    // Recent/frequent foods (from NutritionEntry)
    @State private var recentEntries: [NutritionEntry] = []
    @State private var loadingRecent = false

    // Saved/custom foods
    @State private var savedFoods: [FoodSearchResult] = []
    @State private var savedQuery = ""
    @State private var loadingSaved = false

    // Manual entry
    @State private var manualName = ""
    @State private var manualCal = ""
    @State private var manualProtein = ""
    @State private var manualCarbs = ""
    @State private var manualFat = ""
    @State private var manualQty = "100"
    @State private var saveAsCustom = true
    @State private var saving = false

    init(date: String, defaultMeal: String = "snack", onSave: @escaping () -> Void) {
        self.date = date
        self.defaultMeal = defaultMeal
        self.onSave = onSave
        _selectedMeal = State(initialValue: defaultMeal)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Meal picker bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["breakfast", "lunch", "dinner", "snack"], id: \.self) { meal in
                            Button(meal.capitalized) {
                                selectedMeal = meal
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedMeal == meal ? Color.blue : Color(.tertiarySystemGroupedBackground))
                            .foregroundStyle(selectedMeal == meal ? .white : .primary)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // Tab segmented control
                Picker("Tab", selection: $activeTab) {
                    Text("Search").tag(Tab.search)
                    Text("Recent").tag(Tab.recent)
                    Text("My Foods").tag(Tab.saved)
                    Text("Manual").tag(Tab.manual)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .onChange(of: activeTab) { _, tab in
                    if tab == .saved && savedFoods.isEmpty { Task { await loadSavedFoods() } }
                    if tab == .recent && recentEntries.isEmpty { Task { await loadRecent() } }
                }

                switch activeTab {
                case .search:   searchTab
                case .recent:   recentTab
                case .saved:    savedTab
                case .manual:   manualEntryForm
                }
            }
            .navigationTitle("Add Food")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if activeTab == .manual {
                        Button {
                            Task { await saveManual() }
                        } label: {
                            if saving { ProgressView() } else { Text("Save") }
                        }
                        .disabled(saving || manualName.isEmpty)
                    } else if activeTab == .search {
                        Button { showScanner = true } label: {
                            Image(systemName: "barcode.viewfinder")
                        }
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView { barcode in
                    showScanner = false
                    Task { await lookupBarcode(barcode) }
                }
            }
            .sheet(isPresented: $showLabelScanner) {
                NutritionLabelScanner(barcode: pendingBarcode) { scanned in
                    showLabelScanner = false
                    manualName = scanned.name
                    manualCal = scanned.calories > 0 ? "\(Int(scanned.calories))" : ""
                    manualProtein = scanned.protein > 0 ? "\(Int(scanned.protein))" : ""
                    manualCarbs = scanned.carbs > 0 ? "\(Int(scanned.carbs))" : ""
                    manualFat = scanned.fat > 0 ? "\(Int(scanned.fat))" : ""
                    activeTab = .manual
                }
            }
            .sheet(item: $selectedFoodWrapper) { wrapper in
                FoodDetailSheet(food: wrapper.food, date: date, meal: selectedMeal) {
                    onSave()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Search Tab

    private var searchTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search foods...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await search() } }
                if !searchQuery.isEmpty {
                    Button { searchQuery = ""; searchResults = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding([.horizontal, .bottom])

            if searching {
                ProgressView().padding(.top, 40)
                Spacer()
            } else if searchResults.isEmpty && !searchQuery.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No results found").foregroundStyle(.secondary)
                }
                .padding(.top, 60)
                Spacer()
            } else if searchResults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("Search for a food or scan a barcode").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 60)
                Spacer()
            } else {
                foodList(searchResults)
            }
        }
    }

    // MARK: - Recent Tab

    private var recentTab: some View {
        VStack(spacing: 0) {
            if loadingRecent {
                ProgressView().padding(.top, 40)
                Spacer()
            } else if recentEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("No recent foods").font(.subheadline).foregroundStyle(.secondary)
                    Text("Foods you've logged will appear here.").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.top, 60)
                Spacer()
            } else {
                List(recentEntries) { entry in
                    Button {
                        Task { await relogEntry(entry) }
                    } label: {
                        recentFoodRow(entry)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task { if recentEntries.isEmpty { await loadRecent() } }
    }

    private func recentFoodRow(_ entry: NutritionEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let cal = entry.calories { Text("\(Int(cal)) kcal").foregroundStyle(.orange) }
                    if let q = entry.quantity_g, q > 0 { Text("·").foregroundStyle(.tertiary); Text("\(Int(q))g").foregroundStyle(.secondary) }
                }
                .font(.caption2)
            }
            Spacer()
            Image(systemName: "plus.circle").foregroundStyle(.blue)
        }
    }

    // MARK: - Saved Tab

    private var savedTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter saved foods...", text: $savedQuery)
                    .textFieldStyle(.plain)
                    .onChange(of: savedQuery) { _, _ in
                        Task { await loadSavedFoods() }
                    }
                if !savedQuery.isEmpty {
                    Button { savedQuery = ""; Task { await loadSavedFoods() } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding([.horizontal, .bottom])

            if loadingSaved {
                ProgressView().padding(.top, 40)
                Spacer()
            } else if savedFoods.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark.slash").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("No saved foods yet")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Log a food manually and toggle\n\"Save to My Foods\" to save it here.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)
                Spacer()
            } else {
                List {
                    ForEach(savedFoods, id: \.name) { food in
                        Button { selectedFoodWrapper = IdentifiedFood(food: food) } label: {
                            foodRow(food)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if let foodId = food.id {
                                Button(role: .destructive) {
                                    Task { await deleteCustomFood(id: foodId) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func foodList(_ foods: [FoodSearchResult]) -> some View {
        List(foods, id: \.name) { food in
            Button { selectedFoodWrapper = IdentifiedFood(food: food) } label: {
                foodRow(food)
            }
        }
        .listStyle(.plain)
    }

    private func foodRow(_ food: FoodSearchResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if let brand = food.brand, !brand.isEmpty {
                    Text(brand).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(food.calories_per_100g ?? 0)) kcal")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                if let serving = food.serving_label {
                    Text(serving).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("per 100g").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var manualEntryForm: some View {
        VStack(spacing: 16) {
            TextField("Food name", text: $manualName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Qty (g)").font(.caption).foregroundStyle(.secondary)
                    TextField("100", text: $manualQty)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calories").font(.caption).foregroundStyle(.secondary)
                    TextField("0", text: $manualCal)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Protein").font(.caption).foregroundStyle(.secondary)
                    TextField("0", text: $manualProtein)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Carbs").font(.caption).foregroundStyle(.secondary)
                    TextField("0", text: $manualCarbs)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fat").font(.caption).foregroundStyle(.secondary)
                    TextField("0", text: $manualFat)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                }
            }

            Toggle("Save to My Foods library", isOn: $saveAsCustom)
                .font(.subheadline)
                .padding(.top, 4)
        }
        .padding()
    }

    private func search() async {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        do {
            searchResults = try await APIClient.shared.get("/nutrition/search",
                query: [.init(name: "q", value: searchQuery)])
        } catch { print("[Food] Search: \(error)") }
        searching = false
    }

    private func logFood(_ food: FoodSearchResult, qty: Double? = nil) async {
        let quantity = qty ?? food.serving_size_g ?? 100
        let scale = quantity / 100
        let body = NutritionEntryBody(
            food_item_id: food.id,
            name: food.name + (food.brand != nil ? " (\(food.brand!))" : ""),
            date: date,
            meal: selectedMeal,
            quantity_g: quantity,
            calories: (food.calories_per_100g ?? 0) * scale,
            protein: (food.protein_per_100g ?? 0) * scale,
            carbs: (food.carbs_per_100g ?? 0) * scale,
            fat: (food.fat_per_100g ?? 0) * scale
        )
        do {
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: body)
            onSave()
            dismiss()
        } catch { print("[Food] Log: \(error)") }
    }

    private func loadRecent() async {
        loadingRecent = true
        do {
            recentEntries = try await APIClient.shared.get("/nutrition/entries/recent")
        } catch { print("[Food] Recent: \(error)") }
        loadingRecent = false
    }

    private func relogEntry(_ entry: NutritionEntry) async {
        let body = NutritionEntryBody(
            food_item_id: entry.food_item_id,
            name: entry.name,
            date: date,
            meal: selectedMeal,
            quantity_g: entry.quantity_g ?? 100,
            calories: entry.calories ?? 0,
            protein: entry.protein ?? 0,
            carbs: entry.carbs ?? 0,
            fat: entry.fat ?? 0
        )
        do {
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: body)
            onSave()
            dismiss()
        } catch { print("[Food] Relog: \(error)") }
    }

    private func saveManual() async {
        guard !manualName.isEmpty else { return }
        saving = true
        let qty = Double(manualQty) ?? 100
        let cal = Double(manualCal) ?? 0
        let pro = Double(manualProtein) ?? 0
        let carb = Double(manualCarbs) ?? 0
        let fat = Double(manualFat) ?? 0

        do {
            // Optionally save to custom food library first
            if saveAsCustom && qty > 0 {
                struct FoodCreate: Encodable {
                    let name: String
                    let calories_per_100g: Double
                    let protein_per_100g: Double
                    let carbs_per_100g: Double
                    let fat_per_100g: Double
                    let serving_size_g: Double
                    let serving_label: String
                }
                let scale = 100.0 / qty
                let _: FoodSearchResult = try await APIClient.shared.post("/nutrition/foods/community", body: FoodCreate(
                    name: manualName,
                    calories_per_100g: cal * scale,
                    protein_per_100g: pro * scale,
                    carbs_per_100g: carb * scale,
                    fat_per_100g: fat * scale,
                    serving_size_g: qty,
                    serving_label: "\(Int(qty))g serving"
                ))
            }

            var entry = NutritionEntryBody(
                name: manualName,
                date: date,
                quantity_g: qty,
                calories: cal,
                protein: pro,
                carbs: carb,
                fat: fat
            )
            entry.meal = selectedMeal
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: entry)
            onSave()
            dismiss()
        } catch { print("[Food] Manual: \(error)") }
        saving = false
    }

    private func lookupBarcode(_ barcode: String) async {
        do {
            let food: FoodSearchResult = try await APIClient.shared.get("/nutrition/barcode/\(barcode)")
            selectedFoodWrapper = IdentifiedFood(food: food)
        } catch {
            pendingBarcode = barcode
            showLabelScanner = true
        }
    }

    private func loadSavedFoods() async {
        loadingSaved = true
        do {
            let query = savedQuery.trimmingCharacters(in: .whitespaces)
            var queryItems: [URLQueryItem] = []
            if !query.isEmpty { queryItems.append(.init(name: "q", value: query)) }
            savedFoods = try await APIClient.shared.get("/nutrition/foods", query: queryItems)
        } catch {
            print("[Food] Load saved: \(error)")
        }
        loadingSaved = false
    }

    private func deleteCustomFood(id: Int) async {
        do {
            try await APIClient.shared.delete("/nutrition/foods/\(id)")
            savedFoods.removeAll { $0.id == id }
        } catch { print("[Food] Delete: \(error)") }
    }
}

// MARK: - Food Detail Sheet

struct FoodDetailSheet: View {
    let food: FoodSearchResult
    let date: String
    let meal: String
    let onSave: () -> Void

    @State private var servings: Double = 1
    @State private var customGrams: String = ""
    @State private var useServings: Bool = true
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var servingSize: Double { food.serving_size_g ?? 100 }
    private var quantityG: Double {
        useServings ? servings * servingSize : (Double(customGrams) ?? servingSize)
    }
    private var scale: Double { quantityG / 100 }
    private var displayCalories: Double { (food.calories_per_100g ?? 0) * scale }
    private var displayProtein: Double { (food.protein_per_100g ?? 0) * scale }
    private var displayCarbs: Double { (food.carbs_per_100g ?? 0) * scale }
    private var displayFat: Double { (food.fat_per_100g ?? 0) * scale }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(food.name).font(.headline)
                            if let brand = food.brand, !brand.isEmpty {
                                Text(brand).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(meal.capitalized)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }

                Section("Serving Size") {
                    Toggle("Use servings", isOn: $useServings)

                    if useServings {
                        HStack {
                            Text(food.serving_label ?? "\(Int(servingSize))g")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Stepper(value: $servings, in: 0.25...20, step: 0.25) {
                                Text(String(format: "%.2g", servings))
                                    .font(.title3.weight(.semibold).monospacedDigit())
                            }
                        }
                        Text(String(format: "%.0fg total", quantityG))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Grams")
                            Spacer()
                            TextField("\(Int(servingSize))", text: $customGrams)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("g").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Nutrition") {
                    macroRow("Calories", value: displayCalories, unit: "kcal", color: .orange)
                    macroRow("Protein", value: displayProtein, unit: "g", color: .blue)
                    macroRow("Carbs", value: displayCarbs, unit: "g", color: .green)
                    macroRow("Fat", value: displayFat, unit: "g", color: .yellow)

                    if let micros = food.micronutrients, !micros.isEmpty {
                        let topMicros = [("fiber_g", "Fiber", "g"), ("sodium_mg", "Sodium", "mg"), ("sugar_g", "Sugar", "g")]
                        ForEach(topMicros, id: \.0) { key, name, unit in
                            if let val = micros[key] {
                                HStack {
                                    Text(name).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f %@", val * scale, unit))
                                        .font(.subheadline.monospacedDigit())
                                }
                            }
                        }
                    }
                }

                Text("All values per \(String(format: "%.0f", quantityG))g")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Add to Log")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await logFood() }
                    } label: {
                        if saving { ProgressView() } else { Text("Add").fontWeight(.semibold) }
                    }
                    .disabled(saving || quantityG <= 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            servings = 1
            customGrams = String(format: "%.0f", servingSize)
        }
    }

    private func macroRow(_ label: String, value: Double, unit: String, color: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%.0f", value))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func logFood() async {
        saving = true
        let body = NutritionEntryBody(
            food_item_id: food.id,
            name: food.name + (food.brand != nil ? " (\(food.brand!))" : ""),
            date: date,
            meal: meal,
            quantity_g: quantityG,
            calories: displayCalories,
            protein: displayProtein,
            carbs: displayCarbs,
            fat: displayFat
        )
        do {
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: body)
            onSave()
            dismiss()
        } catch { print("[FoodDetail] Log error: \(error)") }
        saving = false
    }
}

// DietPhaseSheet is defined in DietPhaseSheet.swift

// MARK: - Alcohol Calculator View

struct AlcoholCalculatorView: View {
    let date: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss

    enum DrinkType: String, CaseIterable, Identifiable {
        case beer = "Beer (5% ABV)"
        case wine = "Wine (13% ABV)"
        case spirits = "Spirits (40% ABV)"
        case custom = "Custom"

        var id: String { rawValue }

        var abv: Double? {
            switch self {
            case .beer: return 5.0
            case .wine: return 13.0
            case .spirits: return 40.0
            case .custom: return nil
            }
        }
    }

    enum VolumeUnit: String, CaseIterable {
        case oz = "oz"
        case ml = "ml"
    }

    @State private var drinkType: DrinkType = .beer
    @State private var volumeText: String = ""
    @State private var customABVText: String = ""
    @State private var volumeUnit: VolumeUnit = .oz
    @State private var saving = false

    private var abv: Double {
        if let fixed = drinkType.abv { return fixed }
        return Double(customABVText) ?? 0
    }

    private var volumeML: Double {
        let raw = Double(volumeText) ?? 0
        return volumeUnit == .oz ? raw * 29.5735 : raw
    }

    /// calories = volume_ml × (abv/100) × 0.789 × 7
    private var estimatedCalories: Double {
        volumeML * (abv / 100) * 0.789 * 7
    }

    private var entryName: String {
        let volStr = volumeUnit == .oz
            ? String(format: "%.1foz", Double(volumeText) ?? 0)
            : String(format: "%.0fml", Double(volumeText) ?? 0)
        let abvStr = String(format: "%.1f%%", abv)
        return "Alcohol (\(volStr) \(abvStr))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Drink Type") {
                    Picker("Type", selection: $drinkType) {
                        ForEach(DrinkType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Amount") {
                    HStack {
                        TextField("Volume", text: $volumeText)
                            .keyboardType(.decimalPad)
                        Picker("Unit", selection: $volumeUnit) {
                            ForEach(VolumeUnit.allCases, id: \.self) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 90)
                    }

                    if drinkType == .custom {
                        HStack {
                            Text("ABV %")
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("e.g. 5.0", text: $customABVText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Estimated Calories") {
                    HStack {
                        Text("~\(Int(estimatedCalories.rounded())) kcal")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(estimatedCalories > 0 ? .primary : .secondary)
                        Spacer()
                        if abv > 0 && volumeML > 0 {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.0f ml pure alcohol", volumeML * abv / 100))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.1f g ethanol", volumeML * abv / 100 * 0.789))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: estimatedCalories)
                }

                Section {
                    Button {
                        Task { await logAlcohol() }
                    } label: {
                        HStack {
                            Spacer()
                            if saving {
                                ProgressView()
                            } else {
                                Text("Log Alcohol Entry")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(estimatedCalories <= 0 || saving)
                }
            }
            .navigationTitle("Alcohol Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func logAlcohol() async {
        guard estimatedCalories > 0 else { return }
        saving = true
        let body = NutritionEntryBody(
            name: entryName,
            date: date,
            quantity_g: 0,
            calories: estimatedCalories.rounded(),
            protein: 0,
            carbs: 0,
            fat: 0,
            category: "other"
        )
        do {
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: body)
            onSave()
            dismiss()
        } catch {
            print("[Alcohol] Log error: \(error)")
        }
        saving = false
    }
}

// MARK: - Quick Add View

/// Fast path to log just calories (+ optional protein) without searching
struct QuickAddView: View {
    let date: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss

    @State private var calories: Double? = nil
    @State private var protein: Double? = nil
    @State private var label: String = "Quick Add"
    @State private var mealType: String = "snack"
    @State private var saving = false

    private let mealOptions = ["breakfast", "lunch", "dinner", "snack"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Large calorie input front-and-centre
                    VStack(spacing: 4) {
                        TextField("0", value: $calories, format: .number)
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: .infinity)
                        Text("calories")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Calories")
                }

                Section("Protein (optional)") {
                    HStack {
                        TextField("0", value: $protein, format: .number)
                            .keyboardType(.decimalPad)
                        Text("g")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Label") {
                    TextField("Quick Add", text: $label)
                }

                Section("Meal") {
                    Picker("Meal", selection: $mealType) {
                        ForEach(mealOptions, id: \.self) { m in
                            Text(m.capitalized).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button {
                        Task { await quickLog() }
                    } label: {
                        HStack {
                            Spacer()
                            if saving {
                                ProgressView()
                            } else {
                                Text("Add \(calories.map { "\(Int($0)) kcal" } ?? "")")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(saving || (calories ?? 0) <= 0)
                }
            }
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func quickLog() async {
        guard let cal = calories, cal > 0 else { return }
        saving = true
        let body = NutritionEntryBody(
            name: label.isEmpty ? "Quick Add" : label,
            date: date,
            quantity_g: 0,
            calories: cal,
            protein: protein ?? 0,
            carbs: 0,
            fat: 0,
            category: mealType
        )
        do {
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: body)
            onSave()
            dismiss()
        } catch { print("[QuickAdd] Error: \(error)") }
        saving = false
    }
}

// MARK: - Macro Goals Sheet

struct MacroGoalsSheet: View {
    let currentGoals: MacroGoals?
    let onSave: () -> Void

    @State private var calories: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var waterGoalMl: Double?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(currentGoals: MacroGoals?, onSave: @escaping () -> Void) {
        self.currentGoals = currentGoals
        self.onSave = onSave
        _calories = State(initialValue: currentGoals?.calories)
        _protein = State(initialValue: currentGoals?.protein)
        _carbs = State(initialValue: currentGoals?.carbs)
        _fat = State(initialValue: currentGoals?.fat)
        _waterGoalMl = State(initialValue: currentGoals?.water_goal_ml ?? 2500)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    macroField("Calories (kcal)", value: $calories)
                    macroField("Protein (g)", value: $protein)
                    macroField("Carbs (g)", value: $carbs)
                    macroField("Fat (g)", value: $fat)
                } header: {
                    Text("Daily Macro Goals")
                } footer: {
                    Text("Goals are used to show progress rings in the nutrition view.")
                        .font(.caption)
                }

                Section("Water Goal") {
                    macroField("Water (ml)", value: $waterGoalMl)
                }

                if let cal = calories, let p = protein {
                    Section("Summary") {
                        HStack {
                            Text("Calories")
                            Spacer()
                            Text("\(Int(cal)) kcal")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Protein")
                            Spacer()
                            Text(String(format: "%.0fg (%.0f%%)", p, p * 4 / cal * 100))
                                .foregroundStyle(.secondary)
                        }
                        if let c = carbs {
                            HStack {
                                Text("Carbs")
                                Spacer()
                                Text(String(format: "%.0fg (%.0f%%)", c, c * 4 / cal * 100))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let f = fat {
                            HStack {
                                Text("Fat")
                                Spacer()
                                Text(String(format: "%.0fg (%.0f%%)", f, f * 9 / cal * 100))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Macro Goals")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveGoals() }
                    }
                    .disabled(saving || calories == nil)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func macroField(_ label: String, value: Binding<Double?>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }

    private func saveGoals() async {
        guard let cal = calories else { return }
        saving = true
        struct GoalsBody: Encodable {
            let calories: Double
            let protein: Double
            let carbs: Double
            let fat: Double
            let water_goal_ml: Double?
        }
        let body = GoalsBody(
            calories: cal,
            protein: protein ?? 0,
            carbs: carbs ?? 0,
            fat: fat ?? 0,
            water_goal_ml: waterGoalMl
        )
        do {
            struct GoalsResponse: Decodable { let id: Int? }
            let _: GoalsResponse = try await APIClient.shared.put("/nutrition/goals", body: body)
            onSave()
            dismiss()
        } catch {
            print("[MacroGoals] Save error: \(error)")
        }
        saving = false
    }
}

// MARK: - Water Tracker Card

struct WaterTrackerCard: View {
    let summary: WaterSummary
    let date: String
    let onLog: () -> Void

    @State private var customAmountText = ""
    @State private var showCustomInput = false

    private var progress: Double {
        summary.goal_ml > 0 ? min(summary.total_ml / summary.goal_ml, 1.0) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Water", systemImage: "drop.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                Spacer()
                Text("\(Int(summary.total_ml)) / \(Int(summary.goal_ml)) ml")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.blue.opacity(0.1)).frame(height: 8)
                    Capsule().fill(Color.blue)
                        .frame(width: geo.size.width * progress, height: 8)
                        .animation(.easeInOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 8)

            HStack(spacing: 8) {
                ForEach([250, 500, 750], id: \.self) { amount in
                    Button("+\(amount)ml") {
                        Task { await logWater(Double(amount)) }
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(.blue)
                }

                Spacer()

                Button {
                    showCustomInput.toggle()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            if showCustomInput {
                HStack(spacing: 8) {
                    TextField("ml", text: $customAmountText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Button("Add") {
                        if let ml = Double(customAmountText), ml > 0 {
                            Task { await logWater(ml) }
                            customAmountText = ""
                            showCustomInput = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func logWater(_ amount: Double) async {
        struct WaterBody: Encodable { let date: String; let amount_ml: Double }
        struct WaterResponse: Decodable { let id: Int }
        do {
            let _: WaterResponse = try await APIClient.shared.post("/nutrition/water",
                body: WaterBody(date: date, amount_ml: amount))
            onLog()
        } catch { print("[Water] Log error: \(error)") }
    }
}

// MARK: - Edit Entry Sheet

struct EditEntrySheet: View {
    let entry: NutritionEntry
    let onSave: () -> Void
    let onDelete: () -> Void

    @State private var quantityText: String
    @State private var caloriesText: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String
    @State private var selectedMeal: String
    @State private var saving = false
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    private let mealOptions = ["breakfast", "lunch", "dinner", "snack"]

    init(entry: NutritionEntry, onSave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        self.onDelete = onDelete
        _quantityText = State(initialValue: entry.quantity_g.map { "\(Int($0))" } ?? "100")
        _caloriesText = State(initialValue: entry.calories.map { "\(Int($0))" } ?? "0")
        _proteinText = State(initialValue: entry.protein.map { "\(Int($0))" } ?? "0")
        _carbsText = State(initialValue: entry.carbs.map { "\(Int($0))" } ?? "0")
        _fatText = State(initialValue: entry.fat.map { "\(Int($0))" } ?? "0")
        _selectedMeal = State(initialValue: entry.meal ?? "snack")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Quantity (g)")
                        Spacer()
                        TextField("100", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    Picker("Meal", selection: $selectedMeal) {
                        ForEach(mealOptions, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                } header: { Text(entry.name).textCase(nil) }

                Section("Macros") {
                    macroRow("Calories", text: $caloriesText, unit: "kcal")
                    macroRow("Protein", text: $proteinText, unit: "g")
                    macroRow("Carbs", text: $carbsText, unit: "g")
                    macroRow("Fat", text: $fatText, unit: "g")
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete Entry")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    dismiss()
                    onDelete()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func macroRow(_ label: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text(unit).foregroundStyle(.secondary).font(.caption)
        }
    }

    private func save() async {
        saving = true
        struct UpdateBody: Encodable {
            let quantity_g: Double?
            let calories: Double?
            let protein: Double?
            let carbs: Double?
            let fat: Double?
            let meal: String?
        }
        let body = UpdateBody(
            quantity_g: Double(quantityText),
            calories: Double(caloriesText),
            protein: Double(proteinText),
            carbs: Double(carbsText),
            fat: Double(fatText),
            meal: selectedMeal
        )
        do {
            let _: NutritionEntry = try await APIClient.shared.patch("/nutrition/entries/\(entry.id)", body: body)
            onSave()
            dismiss()
        } catch { print("[EditEntry] Save error: \(error)") }
        saving = false
    }
}
