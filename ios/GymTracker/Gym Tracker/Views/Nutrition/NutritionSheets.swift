import SwiftUI

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
                Section("Quick Presets") {
                    HStack(spacing: 8) {
                        Button("🍺 Beer") {
                            drinkType = .beer; volumeText = "12"; volumeUnit = .oz
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        Button("🍷 Wine") {
                            drinkType = .wine; volumeText = "5"; volumeUnit = .oz
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        Button("🥃 Spirit") {
                            drinkType = .spirits; volumeText = "1.5"; volumeUnit = .oz
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }

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
