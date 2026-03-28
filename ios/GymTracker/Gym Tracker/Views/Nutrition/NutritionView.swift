import SwiftUI

struct NutritionView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @State private var summary: DailySummary?
    @State private var mealEntries: [String: [NutritionEntry]] = [:]
    @State private var waterSummary: WaterSummary?
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
    @State private var editingEntry: NutritionEntry? = nil
    @State private var showCopyDayConfirm = false
    @State private var fabExpanded = false

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
                    VStack(spacing: 0) {
                        // Hero header with date + calorie summary
                        heroHeader

                        if loading {
                            ProgressView().padding(.top, 60)
                        } else {
                            VStack(spacing: 16) {
                                // Macro bars
                                macroDashboard

                                // Phase (compact)
                                phaseCard

                                // Water
                                waterCard

                                // Food log
                                foodLog

                                // Micronutrients
                                micronutrients
                            }
                            .padding(.top, 16)
                        }

                        Spacer(minLength: 90)
                    }
                }
                .background(Color.black)
                .ignoresSafeArea(edges: .top)
                .dismissKeyboardOnTap()

                // FAB
                expandableFAB
            }
            .navigationBarHidden(true)
            .keyboardDoneButton()
            .task { await loadAll(); await loadPhase() }
            .refreshable { await loadAll() }
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
            .confirmationDialog("Copy yesterday's food log?", isPresented: $showCopyDayConfirm, titleVisibility: .visible) {
                Button("Copy") { Task { await copyPreviousDay() } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        let totals = summary?.totals ?? MacroTotals(calories: 0, protein: 0, carbs: 0, fat: 0)
        let goalCal = summary?.goals?.calories ?? (activePhase?.current_goals?.calories)

        return VStack(spacing: 0) {
            // Date row
            HStack {
                Button { shiftDate(-1) } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.medium))
                }
                Spacer()
                VStack(spacing: 0) {
                    Text(Calendar.current.isDateInToday(selectedDate) ? "Today" : selectedDate.formatted(.dateTime.weekday(.wide)))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(selectedDate.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.subheadline)
                }
                Spacer()
                HStack(spacing: 14) {
                    Button { showCopyDayConfirm = true } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    Button { shiftDate(1) } label: {
                        Image(systemName: "chevron.right").font(.body.weight(.medium))
                            .foregroundStyle(Calendar.current.isDateInToday(selectedDate) ? .tertiary : .primary)
                    }
                    .disabled(Calendar.current.isDateInToday(selectedDate))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 54)
            .padding(.bottom, 12)

            // Big calorie number
            VStack(spacing: 4) {
                Text("\(Int(totals.calories))")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                if let goal = goalCal {
                    let rem = goal - totals.calories
                    HStack(spacing: 6) {
                        Text("of \(Int(goal)) kcal")
                            .foregroundStyle(.white.opacity(0.5))
                        Text(rem >= 0 ? "\(Int(rem)) left" : "\(Int(abs(rem))) over")
                            .foregroundStyle(rem >= 0 ? .green : .red)
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                } else {
                    Text("calories")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.bottom, 20)

            // Quick macro pills
            HStack(spacing: 0) {
                macroPill("P", totals.protein, .blue)
                macroPill("C", totals.carbs, .green)
                macroPill("F", totals.fat, .yellow)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [Color(white: 0.12), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func macroPill(_ label: String, _ value: Double, _ color: Color) -> some View {
        let goals = summary?.goals ?? {
            guard let phase = activePhase, let pg = phase.current_goals else { return nil }
            return MacroGoals(calories: pg.calories, protein: pg.protein, carbs: pg.carbs, fat: pg.fat)
        }()
        let goal: Double? = switch label {
        case "P": goals?.protein
        case "C": goals?.carbs
        case "F": goals?.fat
        default: nil
        }

        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
                Text("\(Int(value))g")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                if let g = goal {
                    Text("/ \(Int(g))").font(.caption2).foregroundStyle(.white.opacity(0.3))
                }
            }
            if let g = goal, g > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(color.opacity(0.15)).frame(height: 4)
                        Capsule().fill(value > g ? .red : color)
                            .frame(width: geo.size.width * min(value / g, 1.0), height: 4)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func shiftDate(_ days: Int) {
        if let new = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            selectedDate = new
            loading = true
            Task { await loadAll() }
        }
    }

    // MARK: - Phase Card

    private var phaseCard: some View {
        Group {
            if let phase = activePhase {
                VStack(spacing: 8) {
                    HStack {
                        HStack(spacing: 6) {
                            Text(phaseIcon(phase.phase_type))
                            Text(phase.phase_type.capitalized)
                                .font(.subheadline.weight(.semibold))
                            Text("Week \(phase.current_week ?? 1)/\(phase.duration_weeks ?? 12)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("End") { Task { await endPhase(phase.id) } }
                            .font(.caption2).foregroundStyle(.red.opacity(0.7))
                    }
                    let progress = Double(phase.current_week ?? 1) / Double(phase.duration_weeks ?? 12)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.06)).frame(height: 4)
                            Capsule().fill(phaseColor(phase.phase_type))
                                .frame(width: geo.size.width * min(progress, 1.0), height: 4)
                        }
                    }
                    .frame(height: 4)
                    if let start = phase.starting_weight_kg, let target = phase.target_weight_kg {
                        let u = weightUnit == "lbs" ? 2.20462 : 1.0
                        HStack {
                            Text(String(format: "%.0f", start * u)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if let cur = phase.current_weight_kg {
                                Text(String(format: "%.0f %@", cur * u, weightUnit)).font(.caption2.weight(.semibold))
                            }
                            Spacer()
                            Text(String(format: "%.0f", target * u)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .background(Color(white: 0.11))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            } else {
                Button { showPhaseSheet = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.blue)
                        Text("Start a diet phase").font(.subheadline).foregroundStyle(.blue)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(white: 0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Macro Dashboard

    @ViewBuilder
    private var macroDashboard: some View {
        let goals = summary?.goals ?? {
            guard let phase = activePhase, let pg = phase.current_goals else { return nil }
            return MacroGoals(calories: pg.calories, protein: pg.protein, carbs: pg.carbs, fat: pg.fat)
        }()

        if goals == nil {
            Button { showGoalsSheet = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "target").foregroundStyle(.blue)
                    Text("Set macro goals to track progress").font(.subheadline).foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(white: 0.11))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
        } else {
            // Goals edit button
            HStack {
                Spacer()
                Button { showGoalsSheet = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Goals")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, -8)
        }
    }

    // MARK: - Water Card

    @ViewBuilder
    private var waterCard: some View {
        if let water = waterSummary {
            WaterTrackerCard(summary: water, date: dateString, onLog: { Task { await loadWater() } })
                .padding(.horizontal)
        }
    }

    // MARK: - Micronutrients

    private struct MicroItem {
        let key: String; let name: String; let unit: String; let color: Color
    }

    private let microItems: [MicroItem] = [
        .init(key: "fiber_g", name: "Fiber", unit: "g", color: .green),
        .init(key: "sugar_g", name: "Sugar", unit: "g", color: .orange),
        .init(key: "sodium_mg", name: "Sodium", unit: "mg", color: .red),
        .init(key: "cholesterol_mg", name: "Cholesterol", unit: "mg", color: .yellow),
        .init(key: "calcium_mg", name: "Calcium", unit: "mg", color: .blue),
        .init(key: "iron_mg", name: "Iron", unit: "mg", color: Color.brown),
        .init(key: "potassium_mg", name: "Potassium", unit: "mg", color: .purple),
        .init(key: "magnesium_mg", name: "Magnesium", unit: "mg", color: .teal),
        .init(key: "vitamin_c_mg", name: "Vitamin C", unit: "mg", color: .orange),
        .init(key: "vitamin_d_mcg", name: "Vitamin D", unit: "mcg", color: .yellow),
        .init(key: "vitamin_b12_mcg", name: "B12", unit: "mcg", color: .cyan),
        .init(key: "omega3_g", name: "Omega-3", unit: "g", color: .blue),
    ]

    @ViewBuilder
    private var micronutrients: some View {
        if let micros = summary?.micronutrient_totals, !micros.isEmpty {
            let present = microItems.filter { micros[$0.key] != nil }
            if !present.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Micronutrients").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(present, id: \.key) { item in
                            if let val = micros[item.key] {
                                HStack(spacing: 6) {
                                    Circle().fill(item.color.opacity(0.25)).frame(width: 6, height: 6)
                                    Text(item.name).font(.caption2).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Text("\(formatMicro(val)) \(item.unit)")
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                }
                                .padding(.vertical, 5).padding(.horizontal, 8)
                                .background(Color(white: 0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                .padding(14)
                .background(Color(white: 0.11))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
        }
    }

    private func formatMicro(_ val: Double) -> String {
        if val >= 100 { return String(format: "%.0f", val) }
        if val >= 10 { return String(format: "%.1f", val) }
        return String(format: "%.2f", val)
    }

    // MARK: - Food Log

    private var foodLog: some View {
        VStack(spacing: 0) {
            if allEntries.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.15))
                    Text("No food logged")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.4))
                    HStack(spacing: 10) {
                        Button { showAddFood = true } label: {
                            Label("Add Food", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        Button { showCopyDayConfirm = true } label: {
                            Label("Copy Yesterday", systemImage: "doc.on.doc")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.white.opacity(0.08))
                                .foregroundStyle(.white.opacity(0.6))
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.11))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            } else {
                let orderedMeals = ["breakfast", "lunch", "dinner", "snack"]
                let presentMeals = orderedMeals.filter { !(mealEntries[$0]?.isEmpty ?? true) }
                let otherMeals = mealEntries.keys.filter { !orderedMeals.contains($0) }.sorted()

                VStack(spacing: 8) {
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
        let mealCal = entries.compactMap(\.calories).reduce(0, +)
        let icon: String = switch meal {
        case "breakfast": "sun.horizon.fill"
        case "lunch": "sun.max.fill"
        case "dinner": "moon.fill"
        default: "fork.knife"
        }

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2).foregroundStyle(.white.opacity(0.4))
                Text(meal.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("\(Int(mealCal))").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.orange)
                Text("kcal").font(.caption2).foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            List {
                ForEach(entries) { entry in
                    foodRow(entry)
                        .listRowBackground(Color(white: 0.11))
                        .listRowSeparatorTint(Color.white.opacity(0.04))
                        .listRowInsets(EdgeInsets())
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await deleteEntry(entry.id); await loadAll() }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await duplicateEntry(entry) }
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .tint(.blue)
                        }
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .frame(minHeight: CGFloat(entries.count) * 60)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func foodRow(_ entry: NutritionEntry) -> some View {
        let p = entry.protein ?? 0, c = entry.carbs ?? 0, f = entry.fat ?? 0
        let total = p + c + f
        let pFrac = total > 0 ? p / total : 0
        let cFrac = total > 0 ? c / total : 0

        return Button { editingEntry = entry } label: {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            if let cal = entry.calories {
                                Text("\(Int(cal))").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.orange)
                                Text("kcal").font(.caption2).foregroundStyle(.tertiary)
                            }
                            if let q = entry.quantity_g, q > 0 {
                                Text("\(Int(q))g").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        macroChip("P", p, .blue)
                        macroChip("C", c, .green)
                        macroChip("F", f, .yellow)
                    }
                }
                // Inline macro proportion bar
                if total > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            Rectangle().fill(Color.blue).frame(width: geo.size.width * pFrac)
                            Rectangle().fill(Color.green).frame(width: geo.size.width * cFrac)
                            Rectangle().fill(Color.yellow)
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func macroChip(_ label: String, _ value: Double, _ color: Color) -> some View {
        Text("\(Int(value))")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
    }

    // MARK: - Expandable FAB

    private var expandableFAB: some View {
        VStack(spacing: 10) {
            if fabExpanded {
                fabAction(icon: "plus.circle.fill", label: "Add Food") { showAddFood = true }
                fabAction(icon: "barcode.viewfinder", label: "Scan") { showScanner = true }
                fabAction(icon: "bolt.fill", label: "Quick Add") { showQuickAdd = true }
                fabAction(icon: "fork.knife", label: "Recipes") { showRecipes = true }
                fabAction(icon: "wineglass.fill", label: "Alcohol") { showAlcoholCalc = true }
            }

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    fabExpanded.toggle()
                }
            } label: {
                Image(systemName: fabExpanded ? "xmark" : "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(fabExpanded ? Color.gray : Color.blue)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .rotationEffect(.degrees(fabExpanded ? 90 : 0))
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }

    private func fabAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.25)) { fabExpanded = false }
            action()
        } label: {
            HStack(spacing: 8) {
                Text(label).font(.caption.weight(.medium))
                Image(systemName: icon).font(.body)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.5).combined(with: .opacity),
            removal: .opacity
        ))
    }

    // MARK: - Helpers

    private func phaseIcon(_ type: String) -> String {
        switch type { case "cut": "🔽"; case "bulk": "🔼"; default: "⚖️" }
    }

    private func phaseColor(_ type: String) -> Color {
        switch type { case "cut": .red; case "bulk": .green; default: .blue }
    }

    // MARK: - Data Loading (fully sequential — no async let)

    private func loadAll() async {
        do {
            summary = try await APIClient.shared.get("/nutrition/summary",
                query: [.init(name: "date", value: dateString)])
        } catch { print("[Nutrition] Summary: \(error)") }
        do {
            let response: EntriesResponse = try await APIClient.shared.get("/nutrition/entries",
                query: [.init(name: "date", value: dateString)])
            mealEntries = response.meals
        } catch { print("[Nutrition] Entries: \(error)") }
        do {
            waterSummary = try await APIClient.shared.get("/nutrition/water",
                query: [.init(name: "date", value: dateString)])
        } catch { print("[Nutrition] Water: \(error)") }
        loading = false
    }

    private func loadWater() async {
        do {
            waterSummary = try await APIClient.shared.get("/nutrition/water",
                query: [.init(name: "date", value: dateString)])
        } catch { print("[Nutrition] Water: \(error)") }
    }

    private func loadPhase() async {
        activePhase = try? await APIClient.shared.get("/nutrition/phases/active")
    }

    private func deleteEntry(_ id: Int) async {
        do {
            try await APIClient.shared.delete("/nutrition/entries/\(id)")
        } catch { print("[Nutrition] Delete error: \(error)") }
    }

    private func duplicateEntry(_ entry: NutritionEntry) async {
        let body = NutritionEntryBody(
            food_item_id: entry.food_item_id,
            name: entry.name,
            date: dateString,
            meal: entry.meal ?? "snack",
            quantity_g: entry.quantity_g ?? 100,
            calories: entry.calories ?? 0,
            protein: entry.protein ?? 0,
            carbs: entry.carbs ?? 0,
            fat: entry.fat ?? 0
        )
        do {
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: body)
        } catch { print("[Nutrition] Duplicate error: \(error)") }
        await loadAll()
    }

    private func copyPreviousDay() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        do {
            struct R: Decodable { let copied: Int }
            let _: R = try await APIClient.shared.post("/nutrition/entries/copy-day",
                queryItems: [.init(name: "from_date", value: df.string(from: yesterday)),
                             .init(name: "to_date", value: dateString)])
        } catch { print("[Nutrition] CopyDay: \(error)") }
        await loadAll()
    }

    private func endPhase(_ id: Int) async {
        do {
            try await APIClient.shared.delete("/nutrition/phases/active")
            activePhase = nil
            await loadAll()
        } catch { print("[Phase] End error: \(error)") }
    }

    private func lookupBarcode(_ barcode: String) async {
        do {
            let food: FoodSearchResult = try await APIClient.shared.get("/nutrition/barcode/\(barcode)")
            let qty = food.serving_size_g ?? 100
            let scale = qty / 100
            let body = NutritionEntryBody(
                name: food.name + (food.brand.map { " (\($0))" } ?? ""),
                date: dateString,
                quantity_g: qty,
                calories: (food.calories_per_100g ?? 0) * scale,
                protein: (food.protein_per_100g ?? 0) * scale,
                carbs: (food.carbs_per_100g ?? 0) * scale,
                fat: (food.fat_per_100g ?? 0) * scale
            )
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: body)
            await loadAll()
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
}

struct IdentifiedFood: Identifiable {
    let id = UUID()
    let food: FoodSearchResult
}

// MARK: - Water Tracker Card

struct WaterTrackerCard: View {
    let summary: WaterSummary
    let date: String
    let onLog: () -> Void
    @State private var showCustom = false
    @State private var customText = ""

    private var progress: Double { summary.goal_ml > 0 ? min(summary.total_ml / summary.goal_ml, 1.0) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Water", systemImage: "drop.fill").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                Spacer()
                Text("\(Int(summary.total_ml)) / \(Int(summary.goal_ml)) ml")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.blue.opacity(0.1)).frame(height: 6)
                    Capsule().fill(Color.blue)
                        .frame(width: geo.size.width * progress, height: 6)
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }
            }
            .frame(height: 6)
            HStack(spacing: 6) {
                ForEach([250, 500, 750], id: \.self) { ml in
                    Button("+\(ml)") { Task { await log(Double(ml)) } }
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule()).foregroundStyle(.blue)
                }
                Spacer()
                if showCustom {
                    HStack(spacing: 4) {
                        TextField("ml", text: $customText).keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder).frame(width: 55)
                        Button("Add") {
                            if let v = Double(customText), v > 0 { Task { await log(v) }; customText = ""; showCustom = false }
                        }.font(.caption2.weight(.medium))
                    }
                } else {
                    Button { showCustom = true } label: {
                        Image(systemName: "plus.circle").font(.caption).foregroundStyle(.blue)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func log(_ ml: Double) async {
        struct B: Encodable { let date: String; let amount_ml: Double }
        struct R: Decodable { let id: Int }
        do {
            let _: R = try await APIClient.shared.post("/nutrition/water", body: B(date: date, amount_ml: ml))
        } catch { print("[Water] Log error: \(error)") }
        onLog()
    }
}

// MARK: - Edit Entry Sheet

struct EditEntrySheet: View {
    let entry: NutritionEntry
    let onSave: () -> Void
    let onDelete: () -> Void
    @State private var qty: String
    @State private var cal: String
    @State private var pro: String
    @State private var carb: String
    @State private var fat: String
    @State private var meal: String
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var errorMessage: String? = nil
    @Environment(\.dismiss) private var dismiss

    init(entry: NutritionEntry, onSave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry; self.onSave = onSave; self.onDelete = onDelete
        _qty = State(initialValue: entry.quantity_g.map { "\(Int($0))" } ?? "100")
        _cal = State(initialValue: entry.calories.map { "\(Int($0))" } ?? "0")
        _pro = State(initialValue: entry.protein.map { "\(Int($0))" } ?? "0")
        _carb = State(initialValue: entry.carbs.map { "\(Int($0))" } ?? "0")
        _fat = State(initialValue: entry.fat.map { "\(Int($0))" } ?? "0")
        _meal = State(initialValue: entry.meal ?? "snack")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Quantity (g)")
                        Spacer()
                        TextField("100", text: $qty)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    Picker("Meal", selection: $meal) {
                        ForEach(["breakfast", "lunch", "dinner", "snack"], id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }
                } header: {
                    Text(entry.name).textCase(nil)
                }

                Section("Macros") {
                    macroField("Calories", text: $cal, unit: "kcal")
                    macroField("Protein", text: $pro, unit: "g")
                    macroField("Carbs", text: $carb, unit: "g")
                    macroField("Fat", text: $fat, unit: "g")
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }

                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        HStack { Spacer(); Text("Delete Entry"); Spacer() }
                    }
                }
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .dismissKeyboardOnTap()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { dismiss(); onDelete() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func macroField(_ label: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() async {
        saving = true
        errorMessage = nil

        struct UpdateBody: Encodable {
            let quantity_g: Double?
            let calories: Double?
            let protein: Double?
            let carbs: Double?
            let fat: Double?
            let meal: String?
        }

        do {
            let body = UpdateBody(
                quantity_g: Double(qty),
                calories: Double(cal),
                protein: Double(pro),
                carbs: Double(carb),
                fat: Double(fat),
                meal: meal
            )
            struct PatchResponse: Decodable { let id: Int }
            let _: PatchResponse = try await APIClient.shared.patch(
                "/nutrition/entries/\(entry.id)", body: body)
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            print("[EditEntry] Save error: \(error)")
        }
        saving = false
    }
}

// MARK: - Serving Size Sheet

struct ServingSizeSheet: View {
    let food: FoodSearchResult
    let date: String
    let onSave: () -> Void

    @State private var servings: Double = 1.0
    @State private var customGrams: String = ""
    @State private var useServings = true
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var servingG: Double { food.serving_size_g ?? 100 }
    private var quantity: Double { useServings ? servings * servingG : (Double(customGrams) ?? servingG) }
    private var scale: Double { quantity / 100 }
    private var cal: Double { (food.calories_per_100g ?? 0) * scale }
    private var pro: Double { (food.protein_per_100g ?? 0) * scale }
    private var carb: Double { (food.carbs_per_100g ?? 0) * scale }
    private var fat: Double { (food.fat_per_100g ?? 0) * scale }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Food info
                VStack(spacing: 4) {
                    Text(food.name).font(.headline)
                    if let brand = food.brand, !brand.isEmpty {
                        Text(brand).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)

                // Serving toggle
                Picker("Mode", selection: $useServings) {
                    Text("Servings").tag(true)
                    Text("Grams").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if useServings {
                    VStack(spacing: 8) {
                        Text(food.serving_label ?? "\(Int(servingG))g serving")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 20) {
                            Button { if servings > 0.25 { servings -= 0.25 } } label: {
                                Image(systemName: "minus.circle.fill").font(.title2).foregroundStyle(.secondary)
                            }
                            Text(String(format: servings == floor(servings) ? "%.0f" : "%.2g", servings))
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .frame(minWidth: 60)
                            Button { servings += 0.25 } label: {
                                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.blue)
                            }
                        }
                        Text(String(format: "%.0fg total", quantity))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    HStack {
                        TextField("\(Int(servingG))", text: $customGrams)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .frame(width: 120)
                        Text("g").font(.title3).foregroundStyle(.secondary)
                    }
                }

                // Macro preview
                HStack(spacing: 0) {
                    macroPreview("Cal", cal, .orange)
                    macroPreview("P", pro, .blue)
                    macroPreview("C", carb, .green)
                    macroPreview("F", fat, .yellow)
                }
                .padding(.horizontal)

                Spacer()

                // Log button
                Button {
                    Task { await logFood() }
                } label: {
                    if saving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Add \(Int(cal)) kcal")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saving || quantity <= 0)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Log Food")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .dismissKeyboardOnTap()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            customGrams = "\(Int(servingG))"
        }
    }

    private func macroPreview(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(value))").font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func logFood() async {
        saving = true
        let body = NutritionEntryBody(
            food_item_id: food.id,
            name: food.name + (food.brand.map { " (\($0))" } ?? ""),
            date: date,
            quantity_g: quantity,
            calories: cal,
            protein: pro,
            carbs: carb,
            fat: fat
        )
        do {
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: body)
            onSave()
            dismiss()
        } catch { print("[ServingSize] Log error: \(error)") }
        saving = false
    }
}

// MARK: - Add Food View

struct AddFoodView: View {
    let date: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss

    enum Tab { case search, saved, manual }
    @State private var activeTab: Tab = .search

    @State private var searchQuery = ""
    @State private var searchResults: [FoodSearchResult] = []
    @State private var searching = false
    @State private var showScanner = false
    @State private var showLabelScanner = false
    @State private var pendingBarcode: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var recentEntries: [NutritionEntry] = []
    @State private var loadingRecent = false
    @State private var selectedFoodWrapper: IdentifiedFood? = nil

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab segmented control
                Picker("Tab", selection: $activeTab) {
                    Text("Search").tag(Tab.search)
                    Text("My Foods").tag(Tab.saved)
                    Text("Manual").tag(Tab.manual)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .onChange(of: activeTab) { _, tab in
                    if tab == .saved && savedFoods.isEmpty {
                        Task { await loadSavedFoods() }
                    }
                }

                switch activeTab {
                case .search:
                    searchTab
                case .saved:
                    savedTab
                case .manual:
                    manualEntryForm
                }
            }
            .navigationTitle("Add Food")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .dismissKeyboardOnTap()
            .task { await loadRecent() }
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
                ServingSizeSheet(food: wrapper.food, date: date) {
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
                    .autocorrectionDisabled()
                    .onChange(of: searchQuery) { _, newValue in
                        debouncedSearch(newValue)
                    }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchResults = []
                        searchTask?.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color(white: 0.08))
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
            } else if searchQuery.isEmpty {
                // Preloaded: recent foods
                if loadingRecent {
                    ProgressView().padding(.top, 40)
                    Spacer()
                } else if recentEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.magnifyingglass").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text("Search for a food or scan a barcode").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                    Spacer()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RECENT").font(.caption2.weight(.semibold)).tracking(0.8)
                            .foregroundStyle(.secondary).padding(.horizontal)
                        List(recentEntries) { entry in
                            Button {
                                Task { await relogEntry(entry) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).font(.subheadline).foregroundStyle(.primary)
                                        HStack(spacing: 4) {
                                            if let cal = entry.calories {
                                                Text("\(Int(cal)) kcal").font(.caption2).foregroundStyle(.orange)
                                            }
                                            if let q = entry.quantity_g, q > 0 {
                                                Text("\(Int(q))g").font(.caption2).foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(.blue)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            } else {
                foodList(searchResults)
            }
        }
    }

    private func debouncedSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            searching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search()
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
            .background(Color(white: 0.08))
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
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                if let label = food.serving_label {
                    Text(label).font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("per 100g").font(.caption2).foregroundStyle(.tertiary)
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

    private func logFood(_ food: FoodSearchResult) async {
        let qty = Double(manualQty) ?? 100
        let scale = qty / 100
        let body = NutritionEntryBody(
            name: food.name + (food.brand.map { " (\($0))" } ?? ""),
            date: date,
            quantity_g: qty,
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

            let entry = NutritionEntryBody(
                name: manualName,
                date: date,
                quantity_g: qty,
                calories: cal,
                protein: pro,
                carbs: carb,
                fat: fat
            )
            let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: entry)
            onSave()
            dismiss()
        } catch { print("[Food] Manual: \(error)") }
        saving = false
    }

    private func lookupBarcode(_ barcode: String) async {
        do {
            let results: [FoodSearchResult] = try await APIClient.shared.get("/nutrition/barcode/\(barcode)")
            if let food = results.first {
                await logFood(food)
            } else {
                pendingBarcode = barcode
                showLabelScanner = true
            }
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
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(currentGoals: MacroGoals?, onSave: @escaping () -> Void) {
        self.currentGoals = currentGoals
        self.onSave = onSave
        _calories = State(initialValue: currentGoals?.calories)
        _protein = State(initialValue: currentGoals?.protein)
        _carbs = State(initialValue: currentGoals?.carbs)
        _fat = State(initialValue: currentGoals?.fat)
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
        }
        let body = GoalsBody(
            calories: cal,
            protein: protein ?? 0,
            carbs: carbs ?? 0,
            fat: fat ?? 0
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
