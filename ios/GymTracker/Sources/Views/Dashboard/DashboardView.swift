import SwiftUI

struct DashboardView: View {
    @State private var plans: [WorkoutPlan] = []
    @State private var recentSessions: [WorkoutSession] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if loading {
                        ProgressView("Loading...")
                            .padding(.top, 40)
                    } else {
                        // Next workout card
                        if let nextPlan = plans.first {
                            NextWorkoutCard(plan: nextPlan)
                        }

                        // Recent workouts
                        if !recentSessions.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Recent Workouts")
                                    .font(.headline)
                                    .padding(.horizontal)

                                ForEach(recentSessions.prefix(5)) { session in
                                    SessionRow(session: session)
                                }
                            }
                        }

                        // Plans
                        NavigationLink("Manage Plans") {
                            PlansListView()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                }
                .padding()
            }
            .navigationTitle("Training")
            .task { await loadData() }
            .refreshable { await loadData() }
        }
    }

    private func loadData() async {
        do {
            async let p: [WorkoutPlan] = APIClient.shared.get("/plans/")
            async let s: [WorkoutSession] = APIClient.shared.get("/sessions/", query: [.init(name: "limit", value: "10")])
            plans = try await p
            recentSessions = try await s.filter { $0.status == "completed" }
            loading = false
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }
}

struct NextWorkoutCard: View {
    let plan: WorkoutPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next Workout")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(plan.name)
                .font(.title3.bold())

            NavigationLink("Start Workout") {
                // TODO: ActiveWorkoutView
                Text("Workout will go here")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SessionRow: View {
    let session: WorkoutSession

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(session.name ?? "Workout")
                    .font(.subheadline.bold())
                if let date = session.date {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let sets = session.total_sets {
                Text("\(sets) sets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct PlansListView: View {
    var body: some View {
        Text("Plans management — coming soon")
            .navigationTitle("Plans")
    }
}
