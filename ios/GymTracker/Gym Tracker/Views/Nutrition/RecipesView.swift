import SwiftUI

// MARK: - Recipe List View

struct RecipesView: View {
    let date: String
    let onLog: () -> Void

    @State private var recipes: [RecipeModel] = []
    @State private var loading = true
    @State private var showBuilder = false
    @State private var editingRecipe: RecipeModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if recipes.isEmpty {
                    emptyState
                } else {
                    recipeList
                }
            }
            .navigationTitle("My Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingRecipe = nil
                        showBuilder = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showBuilder, onDismiss: { Task { await loadRecipes() } }) {
                RecipeBuilderView(existing: editingRecipe)
            }
            .task { await loadRecipes() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "fork.knife")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No recipes yet")
                .font(.title3.bold())
            Text("Create your first recipe to quickly log multi-ingredient meals.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                editingRecipe = nil
                showBuilder = true
            } label: {
                Label("Create Recipe", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recipeList: some View {
        List {
            ForEach(recipes) { recipe in
                NavigationLink {
                    RecipeDetailView(recipe: recipe, date: date, onLog: {
                        onLog()
                        dismiss()
                    }, onUpdated: { Task { await loadRecipes() } })
                } label: {
                    RecipeRowView(recipe: recipe)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await deleteRecipe(recipe) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingRecipe = recipe
                        showBuilder = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func loadRecipes() async {
        loading = true
        do {
            recipes = try await APIClient.shared.get("/recipes/")
        } catch {
            print("[Recipes] Load error: \(error)")
        }
        loading = false
    }

    private func deleteRecipe(_ recipe: RecipeModel) async {
        do {
            try await APIClient.shared.delete("/recipes/\(recipe.id)")
            recipes.removeAll { $0.id == recipe.id }
        } catch {
            print("[Recipes] Delete error: \(error)")
        }
    }
}

// MARK: - Recipe Row

struct RecipeRowView: View {
    let recipe: RecipeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.name)
                .font(.subheadline.bold())
            HStack(spacing: 10) {
                Label("\(Int(recipe.total_calories)) kcal", systemImage: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("P: \(Int(recipe.total_protein))g")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("C: \(Int(recipe.total_carbs))g")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("F: \(Int(recipe.total_fat))g")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
            if recipe.servings > 1 {
                Text("\(formatServings(recipe.servings)) servings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func formatServings(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))" : String(format: "%.1f", s)
    }
}

// MARK: - Recipe Detail View

struct RecipeDetailView: View {
    let recipe: RecipeModel
    let date: String
    let onLog: () -> Void
    let onUpdated: () -> Void

    @State private var servings: Double = 1.0
    @State private var mealType = "lunch"
    @State private var logging = false
    @State private var logDone = false
    @Environment(\.dismiss) private var dismiss

    private let meals = ["breakfast", "lunch", "dinner", "snack"]

    private var scaledCalories: Double { recipe.total_calories * ratio }
    private var scaledProtein: Double { recipe.total_protein * ratio }
    private var scaledCarbs: Double { recipe.total_carbs * ratio }
    private var scaledFat: Double { recipe.total_fat * ratio }
    private var ratio: Double { servings / recipe.servings }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Macro summary card
                macroCard

                // Serving picker
                servingSection

                // Log button
                logSection

                // Ingredient list
                if let ingredients = recipe.ingredients, !ingredients.isEmpty {
                    ingredientsSection(ingredients)
                }
            }
            .padding()
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.large)
    }

    private var macroCard: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
            MacroBox(label: "kcal", value: "\(Int(scaledCalories))", color: .orange)
            MacroBox(label: "Protein", value: "\(Int(scaledProtein))g", color: .blue)
            MacroBox(label: "Carbs", value: "\(Int(scaledCarbs))g", color: .green)
            MacroBox(label: "Fat", value: "\(Int(scaledFat))g", color: .yellow)
        }
    }

    private var servingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Servings")
                .font(.headline)
            HStack {
                Button {
                    if servings > 0.5 { servings -= 0.5 }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                Text(servings == servings.rounded() ? "\(Int(servings))" : String(format: "%.1f", servings))
                    .font(.title2.bold())
                    .frame(width: 60, alignment: .center)
                Button {
                    servings += 0.5
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var logSection: some View {
        VStack(spacing: 12) {
            Picker("Meal", selection: $mealType) {
                ForEach(meals, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)

            Button {
                Task { await logRecipe() }
            } label: {
                HStack {
                    Spacer()
                    if logging {
                        ProgressView()
                    } else if logDone {
                        Label("Logged!", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                    } else {
                        Label("Log Recipe", systemImage: "fork.knife")
                            .font(.headline)
                    }
                    Spacer()
                }
            }
            .frame(height: 50)
            .background(logDone ? Color.green : Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(logging || logDone)
        }
    }

    private func ingredientsSection(_ ingredients: [RecipeIngredientModel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ingredients (\(ingredients.count))")
                .font(.headline)
            ForEach(ingredients) { ing in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ing.name)
                            .font(.subheadline)
                        Text("\(formatQty(ing.quantity)) \(ing.unit)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(ing.calories)) kcal")
                            .font(.caption.bold())
                        Text("P:\(Int(ing.protein))  C:\(Int(ing.carbs))  F:\(Int(ing.fat))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func logRecipe() async {
        logging = true
        let body = RecipeLogBody(date: date, servings: servings, meal_type: mealType)
        do {
            struct LogResponse: Decodable { let id: Int }
            let _: LogResponse = try await APIClient.shared.post("/recipes/\(recipe.id)/log", body: body)
            logDone = true
            onLog()
        } catch {
            print("[RecipeDetail] Log error: \(error)")
        }
        logging = false
    }

    private func formatQty(_ q: Double) -> String {
        q == q.rounded() ? "\(Int(q))" : String(format: "%.1f", q)
    }
}

// MARK: - Recipe Builder View

struct RecipeBuilderView: View {
    let existing: RecipeModel?

    @State private var name = ""
    @State private var description = ""
    @State private var servings: Double = 1.0
    @State private var ingredients: [DraftIngredient] = []
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(existing: RecipeModel? = nil) {
        self.existing = existing
        if let r = existing {
            _name = State(initialValue: r.name)
            _description = State(initialValue: r.description ?? "")
            _servings = State(initialValue: r.servings)
            _ingredients = State(initialValue: r.ingredients?.map {
                DraftIngredient(
                    name: $0.name,
                    quantity: String($0.quantity == $0.quantity.rounded() ? "\(Int($0.quantity))" : String(format: "%.1f", $0.quantity)),
                    unit: $0.unit,
                    calories: "\(Int($0.calories))",
                    protein: "\(Int($0.protein))",
                    carbs: "\(Int($0.carbs))",
                    fat: "\(Int($0.fat))"
                )
            } ?? [])
        }
    }

    private var totalCalories: Double {
        ingredients.compactMap { Double($0.calories) }.reduce(0, +)
    }
    private var totalProtein: Double {
        ingredients.compactMap { Double($0.protein) }.reduce(0, +)
    }
    private var totalCarbs: Double {
        ingredients.compactMap { Double($0.carbs) }.reduce(0, +)
    }
    private var totalFat: Double {
        ingredients.compactMap { Double($0.fat) }.reduce(0, +)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !ingredients.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                // Recipe info
                Section("Recipe Info") {
                    TextField("Recipe Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                    HStack {
                        Text("Servings")
                        Spacer()
                        Stepper("\(Int(servings))", value: $servings, in: 1...99, step: 1)
                    }
                }

                // Macro summary
                if !ingredients.isEmpty {
                    Section("Totals (whole recipe)") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                            MacroBox(label: "kcal", value: "\(Int(totalCalories))", color: .orange)
                            MacroBox(label: "Protein", value: "\(Int(totalProtein))g", color: .blue)
                            MacroBox(label: "Carbs", value: "\(Int(totalCarbs))g", color: .green)
                            MacroBox(label: "Fat", value: "\(Int(totalFat))g", color: .yellow)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Ingredients
                Section {
                    ForEach(ingredients.indices, id: \.self) { i in
                        IngredientRowEditor(ingredient: $ingredients[i])
                    }
                    .onDelete { offsets in ingredients.remove(atOffsets: offsets) }

                    Button {
                        withAnimation { ingredients.append(DraftIngredient()) }
                    } label: {
                        Label("Add Ingredient", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Ingredients")
                }
            }
            .navigationTitle(existing == nil ? "New Recipe" : "Edit Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveRecipe() }
                    }
                    .disabled(!canSave || saving)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func saveRecipe() async {
        saving = true
        let body = RecipeCreateBody(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            servings: servings,
            ingredients: ingredients.compactMap { ing -> RecipeIngredientBody? in
                guard !ing.name.isEmpty else { return nil }
                return RecipeIngredientBody(
                    name: ing.name,
                    quantity: Double(ing.quantity) ?? 1.0,
                    unit: ing.unit.isEmpty ? "serving" : ing.unit,
                    calories: Double(ing.calories) ?? 0,
                    protein: Double(ing.protein) ?? 0,
                    carbs: Double(ing.carbs) ?? 0,
                    fat: Double(ing.fat) ?? 0
                )
            }
        )
        do {
            if let existing {
                let _: RecipeModel = try await APIClient.shared.put("/recipes/\(existing.id)", body: body)
            } else {
                let _: RecipeModel = try await APIClient.shared.post("/recipes/", body: body)
            }
            dismiss()
        } catch {
            print("[RecipeBuilder] Save error: \(error)")
        }
        saving = false
    }
}

// MARK: - Ingredient Row Editor

struct DraftIngredient {
    var name = ""
    var quantity = "1"
    var unit = "serving"
    var calories = ""
    var protein = ""
    var carbs = ""
    var fat = ""
}

struct IngredientRowEditor: View {
    @Binding var ingredient: DraftIngredient

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ingredient name", text: $ingredient.name)
                .font(.subheadline.bold())

            HStack(spacing: 8) {
                TextField("Qty", text: $ingredient.quantity)
                    .keyboardType(.decimalPad)
                    .frame(width: 50)
                TextField("Unit", text: $ingredient.unit)
                    .frame(width: 80)
            }
            .font(.caption)

            HStack(spacing: 8) {
                macroField("kcal", text: $ingredient.calories, color: .orange)
                macroField("P(g)", text: $ingredient.protein, color: .blue)
                macroField("C(g)", text: $ingredient.carbs, color: .green)
                macroField("F(g)", text: $ingredient.fat, color: .yellow)
            }
        }
        .padding(.vertical, 4)
    }

    private func macroField(_ label: String, text: Binding<String>, color: Color) -> some View {
        VStack(spacing: 2) {
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .padding(4)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared Macro Box

struct MacroBox: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
