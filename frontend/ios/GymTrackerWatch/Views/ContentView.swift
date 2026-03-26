import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager

    var body: some View {
        if connectivity.isWorkoutActive, let state = connectivity.workoutState {
            WorkoutView(state: state)
                .environmentObject(connectivity)
        } else {
            IdleView(isReachable: connectivity.isReachable)
        }
    }
}

// MARK: - Idle View (no active workout)
struct IdleView: View {
    let isReachable: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 40))
                .foregroundColor(.blue)

            Text("GymTracker")
                .font(.headline)

            if isReachable {
                Text("Start a workout\non your phone")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "iphone.slash")
                        .font(.caption2)
                    Text("Phone not connected")
                        .font(.caption2)
                }
                .foregroundColor(.orange)
            }
        }
    }
}
