import Foundation
import UIKit

/// Reports the iPad's battery level and charging state to the page, on change and every 5 minutes.
final class BatteryMonitor {
    private let bridge: Bridge
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(bridge: Bridge) {
        self.bridge = bridge
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.push()
        })
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.push()
        })
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.push()
        }
    }

    func push() {
        let device = UIDevice.current
        let level = device.batteryLevel < 0 ? -1 : Int((device.batteryLevel * 100).rounded())
        let state = device.batteryState
        bridge.send([
            "type": "battery",
            "level": level,
            "charging": state == .charging || state == .full,
            "full": state == .full
        ])
    }
}
