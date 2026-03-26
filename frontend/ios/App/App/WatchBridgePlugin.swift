import Foundation
import Capacitor

/// Capacitor plugin that bridges the WebView ↔ WatchConnectivity
@objc(WatchBridgePlugin)
public class WatchBridgePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "WatchBridgePlugin"
    public let jsName = "WatchBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "sendWorkoutState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendWorkoutEnded", returnType: CAPPluginReturnPromise),
    ]

    override public func load() {
        // Give WatchSessionManager access to the webView
        WatchSessionManager.shared.setWebView(bridge?.webView)
    }

    /// Called from JS when workout state changes
    @objc func sendWorkoutState(_ call: CAPPluginCall) {
        guard let stateJSON = call.getString("state") else {
            call.reject("Missing state parameter")
            return
        }
        WatchSessionManager.shared.sendWorkoutState(stateJSON)
        call.resolve()
    }

    /// Called from JS when workout ends
    @objc func sendWorkoutEnded(_ call: CAPPluginCall) {
        WatchSessionManager.shared.sendWorkoutEnded()
        call.resolve()
    }
}
