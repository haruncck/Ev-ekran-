import Foundation
import WebKit

/// Sends messages from the app to the page: window.evNative({...}) (see uygulama/KOPRU.md).
final class Bridge {
    weak var webView: WKWebView?

    func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        run("window.evNative&&window.evNative(\(json))")
    }

    func run(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

/// Everything the app keeps alive while it runs.
final class AppModel: ObservableObject {
    let bridge: Bridge
    let hub: BLEHub
    let battery: BatteryMonitor
    let sound: SoundListener
    let http: LocalHTTP
    let miio: MiIO

    init() {
        let b = Bridge()
        bridge = b
        hub = BLEHub(bridge: b)
        battery = BatteryMonitor(bridge: b)
        sound = SoundListener(bridge: b)
        http = LocalHTTP(bridge: b)
        miio = MiIO(bridge: b)
    }
}
