import SwiftUI

// MARK: - Plans View

struct PlansView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"

    @State private var plans: [WorkoutPlan] = []
    @State private var loading = true
    @State private var expandedPlanId: Int? = nil
    @State private var planToDelete: WorkoutPlan? = nil
    @State private var showDeleteAlert = false
    @State private var actionMessage: String? = nil
    @State private var showTemplates = false
    @State private var showCreatePlan = false

    private var activePlans: [WorkoutPlan] {
        plans.filter { !($0.is_archived ?? false) && !($0.is_draft ?? false) }
    }
    private var draftPlans: [WorkoutPlan] {
        plans.filter { $0.is_draft ?? false }
    }
    private var archivedPlans: [WorkoutPlan] {
        plans.filter { $0.is_archived ?? false }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading plans…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if plans.isEmpty {
                emptyState
            } else {
                planList
            }
        }
        .navigationTitle("Plans")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showCreatePlan = true
                    } label: {
                        Label("Create Plan", systemImage: "plus.circle")
                    }
                    Button {
                        showTemplates = true
                    } label: {
                        Label("Browse Templates", systemImage: "doc.text.magnifyingglass")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showTemplates) {
            TemplatesView()
        }
        .sheet(isPresented: $showCreatePlan) {
            CreatePlanView {
                Task { await loadPlans() }
            }
        }
        .task { await loadPlans() }
        .refreshable { await loadPlans() }
        .alert("Delete Plan?", isPresented: $showDeleteAlert, presenting: planToDelete) { plan in
            Button("Delete", role: .destructive) { Task { await deletePlan(plan) } }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(""\(plan.name)" will be permanently deleted. This cannot be undone.")
        }
        .safeAreaInset(edge: .bottom) {
            if let msg = actionMessage {
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

    // MARK: - Plan List

    private var planList: some View {
        List {
            if !activePlans.isEmpty {
                Section("Active Plans") {
                    ForEach(activePlans) { plan in
                        PlanCardRow(
                            plan: plan,
                            weightUnit: weightUnit,
                            isExpanded: expandedPlanId == plan.id,
                            onToggle: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    expandedPlanId = expandedPlanId == plan.id ? nil : plan.id
                                }
                            }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                Task { await archivePlan(plan) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.orange)

                            Button(role: .destructive) {
                                planToDelete = plan
                                showDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !draftPlans.isEmpty {
                Section("Drafts") {
                    ForEach(draftPlans) { plan in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.name).font(.subheadline)
                                Text("\(plan.dayCount) days • Draft")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Draft")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.yellow.opacity(0.2))
                                .foregroundStyle(.yellow)
                                .clipShape(Capsule())
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                planToDelete = plan
                                showDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !archivedPlans.isEmpty {
                Section {
                    ForEach(archivedPlans) { plan in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plan.name).font(.subheadline).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text("\(plan.dayCount) days").font(.caption).foregroundStyle(.secondary)
                                    if let weeks = plan.duration_weeks {
                                        Text("• \(weeks)wk").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Button("Reuse") {
                                Task { await reusePlan(plan) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                planToDelete = plan
                                showDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Archived").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Plans Yet")
                .font(.title2.bold())
            Text("Create a custom plan or browse pre-built templates to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            HStack(spacing: 12) {
                Button {
                    showCreatePlan = true
                } label: {
                    Label("Create Plan", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showTemplates = true
                } label: {
                    Label("Templates", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadPlans() async {
        do {
            plans = try await APIClient.shared.get("/plans/")
            loading = false
        } catch {
            loading = false
        }
    }

    private func archivePlan(_ plan: WorkoutPlan) async {
        do {
            let _: WorkoutPlan = try await APIClient.shared.post("/plans/\(plan.id)/archive")
            await loadPlans()
            showMessage(""\(plan.name)" archived")
        } catch {}
    }

    private func reusePlan(_ plan: WorkoutPlan) async {
        do {
            let _: WorkoutPlan = try await APIClient.shared.post("/plans/\(plan.id)/reuse")
            await loadPlans()
            showMessage("New copy created")
        } catch {}
    }

    private func deletePlan(_ plan: WorkoutPlan) async {
        do {
            try await APIClient.shared.delete("/plans/\(plan.id)")
            withAnimation { plans.removeAll { $0.id == plan.id } }
        } catch {}
    }

    private func showMessage(_ text: String) {
        withAnimation { actionMessage = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { actionMessage = nil }
        }
    }
}

// MARK: - Plan Card Row

private struct PlanCardRow: View {
    let plan: WorkoutPlan
    let weightUnit: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — tap to expand
            Button(action: onToggle) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(plan.name)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        HStack(spacing: 6) {
                            planBadge("\(plan.dayCount) days", icon: "calendar", color: .blue)
                            if let weeks = plan.duration_weeks {
                                planBadge("\(weeks)wk", icon: "clock", color: .purple)
                            }
                            if let bt = plan.block_type {
                                planBadge(bt.capitalized, icon: "figure.strengthtraining.traditional", color: .orange)
                            }
                            if plan.auto_progression ?? false {
                                planBadge("Auto", icon: "arrow.up.circle", color: .green)
                            }
                        }

                        if let desc = plan.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 1)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                        .font(.title3)
                        .foregroundStyle(isExpanded ? .blue : .secondary)
                }
            }
            .buttonStyle(.plain)

            // Expanded: day list
            if isExpanded {
                if let days = plan.days, !days.isEmpty {
                    Divider().padding(.top, 10).padding(.bottom, 6)
                    ForEach(days) { day in
                        PlanDayLinkRow(plan: plan, day: day, weightUnit: weightUnit)
                    }
                } else {
                    Text("No day details available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
        .padding(.vertical, 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)
    }

    private func planBadge(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Plan Day Row

private struct PlanDayLinkRow: View {
    let plan: WorkoutPlan
    let day: PlanDay
    let weightUnit: String

    @AppStorage(SettingsKey.weightUnit) private var storedUnit: String = "lbs"

    var body: some View {
        NavigationLink {
            ActiveWorkoutView(planId: plan.id, planName: plan.name, dayNumber: day.day_number)
        } label: {
            HStack(spacing: 12) {
                // Day number circle
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Text("\(day.day_number)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(day.day_name)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)

                    if !day.exercises.isEmpty {
                        // Show first 3 exercise names
                        Text(day.exercises.prefix(3).map { $0.displayName }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(day.exercises.count)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text("exercises")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5)
        }
    }
}
