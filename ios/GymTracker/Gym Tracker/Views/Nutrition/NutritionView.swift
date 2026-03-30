import SwiftUI

struct NutritionView: View {
    @Binding private var externalShowGoalsSheet: Bool
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
    @State private var copying = false
    @State private var endingPhase = false
    @State private var scannedFoodWrapper: IdentifiedFood? = nil

    private let meals = ["breakfast", "lunch", "dinner", "snack"]

    init(externalShowGoalsSheet: Binding<Bool> = .constant(false)) {
        _externalShowGoalsSheet = externalShowGoalsSheet
    }

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
                            ProgressView()
                                .tint(.white)
                                .padding(.top, 60)
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
                .background(AppColors.zinc950)
                .ignoresSafeArea(edges: .top)

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
            .sheet(item: $scannedFoodWrapper) { wrapper in
                ServingSizeSheet(food: wrapper.food, date: dateString) {
                    Task { await loadAll() }
                }
            }
            .confirmationDialog("Copy yesterday's food log?", isPresented: $showCopyDayConfirm, titleVisibility: .visible) {
                Button("Copy") { Task { await copyPreviousDay() } }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: externalShowGoalsSheet) { _, shouldShow in
                guard shouldShow else { return }
                showGoalsSheet = true
                externalShowGoalsSheet = false
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
                colors: [AppColors.zinc900, AppColors.zinc950],
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel({
            let name: String = switch label { case "P": "Protein"; case "C": "Carbs"; case "F": "Fat"; default: label }
            if let g = goal { return "\(name): \(Int(value)) of \(Int(g)) grams" }
            return "\(name): \(Int(value)) grams"
        }())
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
                        if endingPhase {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button("End") { Task { await endPhase(phase.id) } }
                                .font(.caption2).foregroundStyle(.red.opacity(0.7))
                        }
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
                .background(AppColors.zinc900)
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
                    .background(AppColors.zinc900)
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
                .background(AppColors.zinc900)
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
                                .background(AppColors.zinc800)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                .padding(14)
                .background(AppColors.zinc900)
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
                .background(AppColors.zinc900)
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
                        .listRowBackground(AppColors.zinc900)
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

    private enum NutrResult: Sendable {
        case summary(DailySummary?)
        case entries(EntriesResponse?)
        case water(WaterSummary?)
    }

    private func loadAll() async {
        let ds = dateString
        let results = await withTaskGroup(of: NutrResult.self, returning: [NutrResult].self) { group in
            group.addTask { .summary(try? await APIClient.shared.get("/nutrition/summary", query: [.init(name: "date", value: ds)])) }
            group.addTask { .entries(try? await APIClient.shared.get("/nutrition/entries", query: [.init(name: "date", value: ds)])) }
            group.addTask { .water(try? await APIClient.shared.get("/nutrition/water", query: [.init(name: "date", value: ds)])) }

            var collected: [NutrResult] = []
            for await r in group { collected.append(r) }
            return collected
        }

        for result in results {
            switch result {
            case .summary(let s): summary = s
            case .entries(let e): mealEntries = e?.meals ?? [:]
            case .water(let w): waterSummary = w
            }
        }
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
        copying = true
        defer { copying = false }
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
        endingPhase = true
        defer { endingPhase = false }
        do {
            try await APIClient.shared.delete("/nutrition/phases/active")
            activePhase = nil
            await loadAll()
        } catch { print("[Phase] End error: \(error)") }
    }

    private func lookupBarcode(_ barcode: String) async {
        do {
            let food: FoodSearchResult = try await APIClient.shared.get("/nutrition/barcode/\(barcode)")
            // Open serving size picker instead of auto-logging (#543)
            scannedFoodWrapper = IdentifiedFood(food: food)
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

struct NutritionEntryBody: Encodable {
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
        .background(AppColors.zinc900)
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

    // Store original per-gram ratios for scaling
    private let originalQty: Double
    private let calPer100: Double
    private let proPer100: Double
    private let carbPer100: Double
    private let fatPer100: Double

    init(entry: NutritionEntry, onSave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry; self.onSave = onSave; self.onDelete = onDelete
        let q = entry.quantity_g ?? 100
        self.originalQty = q > 0 ? q : 100
        self.calPer100 = (entry.calories ?? 0) / (q > 0 ? q : 100) * 100
        self.proPer100 = (entry.protein ?? 0) / (q > 0 ? q : 100) * 100
        self.carbPer100 = (entry.carbs ?? 0) / (q > 0 ? q : 100) * 100
        self.fatPer100 = (entry.fat ?? 0) / (q > 0 ? q : 100) * 100
        _qty = State(initialValue: "\(Int(q))")
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
                            .onChange(of: qty) { _, newQty in
                                // Scale macros proportionally (#535)
                                if let newG = Double(newQty), newG > 0 {
                                    let scale = newG / 100
                                    cal = "\(Int(calPer100 * scale))"
                                    pro = "\(Int(proPer100 * scale))"
                                    carb = "\(Int(carbPer100 * scale))"
                                    fat = "\(Int(fatPer100 * scale))"
                                }
                            }
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

    enum UnitMode: String, CaseIterable {
        case serving = "Serving"
        case grams = "Grams"
        case oz = "Oz"
        case cups = "Cups"
        case tbsp = "Tbsp"
        case ml = "mL"
    }

    // Conversion factors to grams
    private static let toGrams: [UnitMode: Double] = [
        .grams: 1,
        .oz: 28.3495,
        .cups: 236.588,  // ~water/liquid density
        .tbsp: 14.787,
        .ml: 1,  // approx 1ml = 1g for most foods
    ]

    @State private var servings: Double = 1.0
    @State private var customAmount: String = ""
    @State private var unitMode: UnitMode = .serving
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var servingG: Double { food.serving_size_g ?? 100 }
    private var quantity: Double {
        switch unitMode {
        case .serving: return servings * servingG
        default:
            let amount = Double(customAmount) ?? servingG
            return amount * (Self.toGrams[unitMode] ?? 1)
        }
    }
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

                // Unit picker (#541)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(UnitMode.allCases, id: \.self) { mode in
                            Button(mode.rawValue) { unitMode = mode }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(unitMode == mode ? Color.blue : Color(white: 0.15))
                                .foregroundStyle(unitMode == mode ? .white : .secondary)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                }

                if unitMode == .serving {
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
                        TextField("Amount", text: $customAmount)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .frame(width: 120)
                        Text(unitMode.rawValue.lowercased())
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    if unitMode != .grams {
                        Text(String(format: "= %.0fg", quantity))
                            .font(.caption).foregroundStyle(.tertiary)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            customAmount = "\(Int(servingG))"
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
