import Foundation
import WatchConnectivity
import Combine

/// Manages communication between Watch and iPhone via WatchConnectivity
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var workoutState: WorkoutState?
    @Published var isReachable = false
    @Published var isWorkoutActive = false

    private override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    /// Send a set completion to the phone
    func completeSet(exerciseId: Int, setLocalId: String) {
        let message: [String: Any] = [
            "type": "setComplete",
            "exerciseId": exerciseId,
            "setLocalId": setLocalId,
            "action": "complete"
        ]
        sendMessage(message)
    }

    /// Send a skip set to the phone
    func skipSet(exerciseId: Int, setLocalId: String) {
        let message: [String: Any] = [
            "type": "setComplete",
            "exerciseId": exerciseId,
            "setLocalId": setLocalId,
            "action": "skip"
        ]
        sendMessage(message)
    }

    /// Skip the rest timer
    func skipRest() {
        let message: [String: Any] = [
            "type": "skipRest"
        ]
        sendMessage(message)
    }

    private func sendMessage(_ message: [String: Any]) {
        guard WCSession.default.isReachable else {
            print("[Watch] Phone not reachable")
            return
        }
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            print("[Watch] Send error: \(error.localizedDescription)")
        }
    }
}

// MARK: - WCSessionDelegate
extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
        if let error = error {
            print("[Watch] Activation error: \(error.localizedDescription)")
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }

    /// Receive workout state updates from the phone
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        DispatchQueue.main.async {
            switch type {
            case "workoutState":
                if let data = message["data"] as? Data {
                    if let state = try? JSONDecoder().decode(WorkoutState.self, from: data) {
                        self.workoutState = state
                        self.isWorkoutActive = true
                    }
                }
            case "workoutEnded":
                self.workoutState = nil
                self.isWorkoutActive = false
            default:
                break
            }
        }
    }

    /// Receive application context (latest state when Watch wakes up)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["workoutState"] as? Data else {
            DispatchQueue.main.async {
                self.workoutState = nil
                self.isWorkoutActive = false
            }
            return
        }

        if let state = try? JSONDecoder().decode(WorkoutState.self, from: data) {
            DispatchQueue.main.async {
                self.workoutState = state
                self.isWorkoutActive = true
            }
        }
    }
}
