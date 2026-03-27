import SwiftUI

// MARK: - Templates Browse View

struct TemplatesView: View {
    @State private var templates: [WorkoutTemplate] = []
    @State private var loading = true
    @State private var splitFilter: String? = nil
    @State private var equipFilter: String? = nil
    @State private var previewTemplate: WorkoutTemplate? = nil
    @State private var cloning = false
    @State private var toastMessage: String? = nil
    @Environment(\.dismiss) private var dismiss

    private let splits: [(String, String)] = [
        ("full_body", "Full Body"),
        ("upper_lower", "Upper/Lower"),
        ("ppl", "PPL"),
        ("bro_split", "Bro Split"),
    ]
    private let equips: [(String, String)] = [
        ("minimal", "Minimal"),
        ("full_gym", "Full Gym"),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading templates…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if templates.isEmpty {
                    emptyState
                } else {
                    templateList
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $previewTemplate) { tmpl in
                TemplateDetailSheet(template: tmpl, onClone: { await cloneTemplate(tmpl) })
            }
            .task { await loadTemplates() }
            .safeAreaInset(edge: .bottom) {
                if let msg = toastMessage {
                    Text(msg)
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("All Splits", isSelected: splitFilter == nil) { splitFilter = nil }
                    ForEach(splits, id: \.0) { key, label in
                        filterChip(label, isSelected: splitFilter == key) {
                            splitFilter = splitFilter == key ? nil : key
                        }
                    }
                }
                .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("Any Equipment", isSelected: equipFilter == nil) { equipFilter = nil }
                    ForEach(equips, id: \.0) { key, label in
                        filterChip(label, isSelected: equipFilter == key) {
                            equipFilter = equipFilter == key ? nil : key
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.top, 8)
        .onChange(of: splitFilter) { _, _ in Task { await loadTemplates() } }
        .onChange(of: equipFilter) { _, _ in Task { await loadTemplates() } }
    }

    private func filterChip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color.secondary.opacity(0.15))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Template List

    private var templateList: some View {
        List {
            Section {
                filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(templates) { tmpl in
                Button {
                    previewTemplate = tmpl
                } label: {
                    templateRow(tmpl)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func templateRow(_ tmpl: WorkoutTemplate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(splitColor(tmpl.split_type).opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: splitIcon(tmpl.split_type))
                    .font(.title3)
                    .foregroundStyle(splitColor(tmpl.split_type))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(tmpl.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                if let desc = tmpl.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let days = tmpl.days_per_week {
                        badge("\(days)x/week", color: .blue)
                    }
                    if let split = tmpl.split_type {
                        badge(splitLabel(split), color: splitColor(split))
                    }
                    if let equip = tmpl.equipment_tier {
                        badge(equipLabel(equip), color: .gray)
                    }
                    if let count = tmpl.exercise_count {
                        badge("\(count) exercises", color: .secondary)
                    }
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Templates Found")
                .font(.title2.bold())
            Text("Try changing your filters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadTemplates() async {
        var query: [URLQueryItem] = []
        if let s = splitFilter { query.append(.init(name: "split_type", value: s)) }
        if let e = equipFilter { query.append(.init(name: "equipment_tier", value: e)) }
        loading = true
        do {
            templates = try await APIClient.shared.get("/templates/", query: query)
        } catch {
            print("[Templates] Load error: \(error)")
        }
        loading = false
    }

    private func cloneTemplate(_ tmpl: WorkoutTemplate) async {
        struct CloneResponse: Decodable { let id: Int; let name: String }
        do {
            let _: CloneResponse = try await APIClient.shared.post("/templates/\(tmpl.id)/clone")
            showToast(""\(tmpl.name)" added to your plans!")
        } catch {
            showToast("Failed to clone template")
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toastMessage = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { toastMessage = nil }
        }
    }

    // MARK: - Helpers

    private func splitColor(_ split: String?) -> Color {
        switch split {
        case "full_body":    return .green
        case "upper_lower":  return .blue
        case "ppl":          return .purple
        case "bro_split":    return .orange
        default:             return .blue
        }
    }

    private func splitIcon(_ split: String?) -> String {
        switch split {
        case "full_body":    return "figure.strengthtraining.functional"
        case "upper_lower":  return "arrow.up.arrow.down.circle.fill"
        case "ppl":          return "arrow.3.trianglepath"
        case "bro_split":    return "person.fill"
        default:             return "dumbbell.fill"
        }
    }

    private func splitLabel(_ split: String) -> String {
        switch split {
        case "full_body":    return "Full Body"
        case "upper_lower":  return "Upper/Lower"
        case "ppl":          return "PPL"
        case "bro_split":    return "Bro Split"
        default:             return split.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func equipLabel(_ equip: String) -> String {
        switch equip {
        case "minimal":   return "Minimal"
        case "full_gym":  return "Full Gym"
        default:          return equip.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Template Detail Sheet

struct TemplateDetailSheet: View {
    let template: WorkoutTemplate
    let onClone: () async -> Void

    @State private var cloning = false
    @State private var cloned = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 8) {
                        Text(template.name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        if let desc = template.description {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        HStack(spacing: 8) {
                            if let d = template.days_per_week {
                                infoChip("\(d) days/week", icon: "calendar")
                            }
                            if let bt = template.block_type {
                                infoChip(bt.capitalized, icon: "rectangle.stack.fill")
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Days
                    if let days = template.days, !days.isEmpty {
                        ForEach(days, id: \.day_number) { day in
                            dayCard(day)
                        }
                    }

                    // Clone button
                    Button {
                        guard !cloned else { return }
                        cloning = true
                        Task {
                            await onClone()
                            cloning = false
                            cloned = true
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            dismiss()
                        }
                    } label: {
                        Group {
                            if cloning {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else if cloned {
                                Label("Added to Plans!", systemImage: "checkmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("Use This Plan", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cloning || cloned)
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func infoChip(_ label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(label).font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.1))
        .clipShape(Capsule())
    }

    private func dayCard(_ day: WorkoutTemplateDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Text("\(day.day_number)")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
                Text(day.day_name)
                    .font(.subheadline.bold())
                Spacer()
                Text("\(day.exercises.count) exercises")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            if !day.exercises.isEmpty {
                VStack(spacing: 0) {
                    ForEach(day.exercises.indices, id: \.self) { i in
                        let ex = day.exercises[i]
                        HStack(spacing: 8) {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(ex.displayName)
                                .font(.subheadline)
                            Spacer()
                            if let sets = ex.sets, let reps = ex.reps {
                                Text("\(sets)×\(reps)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 5)
                        if i < day.exercises.count - 1 {
                            Divider().padding(.leading, 32)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}
