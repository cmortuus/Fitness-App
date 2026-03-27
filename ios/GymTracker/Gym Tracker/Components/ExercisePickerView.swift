import SwiftUI

struct ExercisePickerView: View {
    let allExercises: [Exercise]
    let onSelect: (Exercise, Int) -> Void // exercise, set count
    var swapMode: Bool = false
    var swapExercise: UIExercise? = nil

    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    @State private var regionFilter = "All"
    @State private var typeFilter = "All"
    @State private var equipFilter = "All"
    @State private var setCount = 4

    let regions = ["All", "Upper", "Lower", "Core"]
    let types = ["All", "Compound", "Isolation"]
    let equipments = ["All", "Barbell", "DB", "Cable", "Machine", "BW", "Smith"]

    private var filtered: [Exercise] {
        allExercises.filter { ex in
            let matchesSearch = search.isEmpty ||
                (ex.display_name ?? "").localizedCaseInsensitiveContains(search) ||
                (ex.muscle_group ?? "").localizedCaseInsensitiveContains(search)
            let matchesRegion = regionFilter == "All" ||
                (ex.muscle_group ?? "").localizedCaseInsensitiveContains(regionFilter)
            let matchesType = typeFilter == "All" ||
                (ex.category ?? "").localizedCaseInsensitiveContains(typeFilter)
            let matchesEquip = equipFilter == "All" ||
                (ex.equipment_type ?? "").localizedCaseInsensitiveContains(equipFilter)
            return matchesSearch && matchesRegion && matchesType && matchesEquip
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search
                TextField("Search exercises...", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Filters
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChips(label: "Region", options: regions, selection: $regionFilter)
                        FilterChips(label: "Type", options: types, selection: $typeFilter)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // Set count picker
                if !swapMode {
                    HStack {
                        Text("Sets:")
                            .font(.subheadline)
                        Spacer()
                        HStack(spacing: 12) {
                            Button(action: { if setCount > 1 { setCount -= 1 } }) {
                                Image(systemName: "minus.circle")
                            }
                            Text("\(setCount)")
                                .font(.title3.bold())
                                .frame(width: 30)
                            Button(action: { if setCount < 10 { setCount += 1 } }) {
                                Image(systemName: "plus.circle")
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }

                // Exercise list
                List(filtered) { exercise in
                    Button(action: {
                        onSelect(exercise, swapMode ? (swapExercise?.sets.count ?? 4) : setCount)
                        dismiss()
                    }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            HStack(spacing: 8) {
                                if let mg = exercise.muscle_group {
                                    Text(mg)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let cat = exercise.category {
                                    Text(cat)
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                                if let eq = exercise.equipment_type {
                                    Text(eq)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(swapMode ? "Swap Exercise" : "Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct FilterChips: View {
    let label: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        ForEach(options, id: \.self) { option in
            Button(option) {
                selection = option
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selection == option ? Color.blue : Color(.systemGray5))
            .foregroundStyle(selection == option ? .white : .primary)
            .clipShape(Capsule())
        }
    }
}
