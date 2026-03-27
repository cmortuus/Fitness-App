import SwiftUI

struct NutritionView: View {
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
            .task { await loadDay(); await loadPhase() }
            .refreshable { await loadDay() }
            .sheet(isPresented: $showAddFood) {
                AddFoodView(date: dateString, onSave: { Task { await loadDay() } })
            }
            .sheet(isPresented: $showPhaseSheet) {
                DietPhaseSheet(activePhase: activePhase, onUpdate: { Task { await loadPhase(); await loadDay() } })
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
                AlcoholCalculatorView(date: dateString, onSave: { Task { await loadDay() } })
            }
            .sheet(isPresented: $showQuickAdd) {
                QuickAddView(date: dateString, onSave: { Task { await loadDay() } })
            }
            .sheet(isPresented: $showRecipes) {
                RecipesView(date: dateString, onLog: { Task { await loadDay() } })
            }
            .sheet(isPresented: $showGoalsSheet) {
                MacroGoalsSheet(currentGoals: summary?.goals, onSave: { Task { await loadDay() } })
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
            selectedDate = new
            loading = true
            Task { await loadDay() }
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
                        HStack {
                            Text(String(format: "%.1f lbs", start * 2.20462))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if let current = phase.current_weight_kg {
                                Text(String(format: "%.1f lbs", current * 2.20462))
                                    .font(.caption2.weight(.semibold))
                            }
                            Spacer()
                            Text(String(format: "%.1f lbs", target * 2.20462))
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

    // MARK: - Food Log

    private var foodLog: some View {
        VStack(spacing: 0) {
            if allEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("No food logged yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("Food Log")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(allEntries.count) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    ForEach(allEntries) { entry in
                        foodRow(entry)
                        if entry.id != allEntries.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            }
        }
    }

    private func foodRow(_ entry: NutritionEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let cal = entry.calories {
                        Text("\(Int(cal)) cal").foregroundStyle(.orange)
                    }
                    if let p = entry.protein, p > 0 {
                        Text("\(Int(p))g P").foregroundStyle(.purple)
                    }
                    if let c = entry.carbs, c > 0 {
                        Text("\(Int(c))g C").foregroundStyle(.orange.opacity(0.7))
                    }
                    if let f = entry.fat, f > 0 {
                        Text("\(Int(f))g F").foregroundStyle(.yellow)
                    }
                }
                .font(.caption2)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await deleteEntry(entry.id) }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        loading = false
    }

    private func loadPhase() async {
        activePhase = try? await APIClient.shared.get("/nutrition/phases/active")
    }

    private func deleteEntry(_ id: Int) async {
        try? await APIClient.shared.delete("/nutrition/entries/\(id)")
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
            let results: [FoodSearchResult] = try await APIClient.shared.get("/nutrition/foods/barcode/\(barcode)")
            if let food = results.first {
                // Auto-log it
                let body = NutritionEntryBody(
                    name: food.name + (food.brand != nil ? " (\(food.brand!))" : ""),
                    date: dateString,
                    quantity_g: 100,
                    calories: food.calories_per_100g ?? 0,
                    protein: food.protein_per_100g ?? 0,
                    carbs: food.carbs_per_100g ?? 0,
                    fat: food.fat_per_100g ?? 0
                )
                let _: NutritionEntry = try await APIClient.shared.post("/nutrition/entries", body: body)
                await loadDay()
            } else {
                pendingBarcode = barcode
                showLabelScanner = true
            }
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
    let name: String
    let date: String
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
                    Text("Log a food manually and toggle\n"Save to My Foods" to save it here.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)
                Spacer()
            } else {
                List {
                    ForEach(savedFoods, id: \.name) { food in
                        Button { Task { await logFood(food) } } label: {
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
            Button { Task { await logFood(food) } } label: {
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
            Text("\(Int(food.calories_per_100g ?? 0)) cal/100g")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            searchResults = try await APIClient.shared.get("/nutrition/foods/search",
                query: [.init(name: "q", value: searchQuery)])
        } catch { print("[Food] Search: \(error)") }
        searching = false
    }

    private func logFood(_ food: FoodSearchResult) async {
        let qty = Double(manualQty) ?? 100
        let scale = qty / 100
        let body = NutritionEntryBody(
            name: food.name + (food.brand != nil ? " (\(food.brand!))" : ""),
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
                let _: [String: String] = try await APIClient.shared.post("/nutrition/foods", body: FoodCreate(
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
            let results: [FoodSearchResult] = try await APIClient.shared.get("/nutrition/foods/barcode/\(barcode)")
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
