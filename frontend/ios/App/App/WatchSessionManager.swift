import Foundation
import WatchConnectivity
import Capacitor

/// Manages WatchConnectivity on the iPhone side.
/// Receives messages from the Watch (set complete, skip rest)
/// and forwards workout state updates to the Watch.
class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    private var webView: WKWebView?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    /// Set the webView reference so we can inject JS callbacks
    func setWebView(_ webView: WKWebView?) {
        self.webView = webView
    }

    /// Send workout state to the Watch
    func sendWorkoutState(_ stateJSON: String) {
        guard WCSession.default.isReachable else {
            // Use application context for background delivery
            if let data = stateJSON.data(using: .utf8) {
                try? WCSession.default.updateApplicationContext(["workoutState": data])
            }
            return
        }

        if let data = stateJSON.data(using: .utf8) {
            WCSession.default.sendMessage(
                ["type": "workoutState", "data": data],
                replyHandler: nil
            ) { error in
                print("[Phone] Send to watch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Notify Watch that workout ended
    func sendWorkoutEnded() {
        let message: [String: Any] = ["type": "workoutEnded"]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
        try? WCSession.default.updateApplicationContext([:])
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("[Phone] WC activation error: \(error.localizedDescription)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for switching watches
        WCSession.default.activate()
    }

    /// Receive messages from Watch (set complete, skip rest)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        DispatchQueue.main.async {
            switch type {
            case "setComplete":
                let exerciseId = message["exerciseId"] as? Int ?? 0
                let setLocalId = message["setLocalId"] as? String ?? ""
                let action = message["action"] as? String ?? "complete"
                // Forward to WebView
                let js = "window.dispatchEvent(new CustomEvent('watchSetAction', { detail: { exerciseId: \(exerciseId), setLocalId: '\(setLocalId)', action: '\(action)' } }))"
                self.webView?.evaluateJavaScript(js, completionHandler: nil)

            case "skipRest":
                let js = "window.dispatchEvent(new CustomEvent('watchSkipRest'))"
                self.webView?.evaluateJavaScript(js, completionHandler: nil)

            default:
                break
            }
        }
    }
}
