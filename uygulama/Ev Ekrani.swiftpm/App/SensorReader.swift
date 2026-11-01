import Foundation
import CoreBluetooth
import WebKit

/// Reads the Xiaomi LYWSD03MMC (square LCD thermometer) every 5 minutes: connect, take one
/// notification (temperature, humidity, battery voltage), disconnect. The short visit keeps the
/// sensor's coin cell lasting. Each reading goes to the page through window.evNativeClimate.
final class SensorReader: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var webView: WKWebView?

    private var central: CBCentralManager!
    private var sensor: CBPeripheral?
    private var latest: (t: Double, h: Int, mv: Int)?
    private var nextRead: Timer?
    private var giveUp: Timer?
    private var busy = false
    private var failures = 0

    private let service = CBUUID(string: "EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let reading = CBUUID(string: "EBE0CCC1-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let savedKey = "sensorIdentifier"
    private let namePrefixes = ["LYWSD03", "ATC_", "MJWSD"]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: cycle

    private func startRead() {
        nextRead?.invalidate()
        guard central.state == .poweredOn, !busy else { return }
        busy = true

        if let known = sensor {
            connect(known)
            return
        }
        if let saved = UserDefaults.standard.string(forKey: savedKey),
           let id = UUID(uuidString: saved),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            sensor = known
            connect(known)
            return
        }
        sendStatus("Sensör aranıyor…")
        central.scanForPeripherals(withServices: nil, options: nil)
        armGiveUp(seconds: 40)
    }

    private func connect(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        armGiveUp(seconds: 25)
    }

    private func finish(success: Bool) {
        giveUp?.invalidate()
        if central.isScanning { central.stopScan() }
        if let p = sensor, p.state != .disconnected {
            central.cancelPeripheralConnection(p)
        }
        busy = false
        if success {
            failures = 0
        } else {
            failures += 1
            // After repeated failures forget the remembered sensor and search again (it may have been replaced).
            if failures >= 4 {
                sensor = nil
                UserDefaults.standard.removeObject(forKey: savedKey)
                failures = 0
            }
            sendStatus("Sensör okunamadı, birazdan yeniden denenecek")
        }
        nextRead = Timer.scheduledTimer(withTimeInterval: success ? 300 : 60, repeats: false) { [weak self] _ in
            self?.startRead()
        }
    }

    private func armGiveUp(seconds: TimeInterval) {
        giveUp?.invalidate()
        giveUp = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.finish(success: false)
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startRead()
        case .unauthorized:
            sendStatus("Bluetooth izni yok: Ayarlar › Gizlilik › Bluetooth")
        case .poweredOff:
            sendStatus("Bluetooth kapalı")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard namePrefixes.contains(where: { name.hasPrefix($0) }) else { return }
        central.stopScan()
        sensor = peripheral
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedKey)
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(success: false)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == service }) else {
            finish(success: false)
            return
        }
        peripheral.discoverCharacteristics([reading], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == reading }) else {
            finish(success: false)
            return
        }
        peripheral.setNotifyValue(true, for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard busy, let data = characteristic.value, data.count >= 3 else { return }
        let b = [UInt8](data)
        let raw = Int16(bitPattern: UInt16(b[0]) | (UInt16(b[1]) << 8))
        let t = Double(raw) / 100.0
        let h = Int(b[2])
        let mv = data.count >= 5 ? Int(UInt16(b[3]) | (UInt16(b[4]) << 8)) : 0
        guard t > -30, t < 70, h <= 100 else { return }
        latest = (t, h, mv)
        pushLatest()
        finish(success: true)
    }

    // MARK: page

    func pushLatest() {
        guard let l = latest else { return }
        let t = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), l.t)
        runJS("window.evNativeClimate&&window.evNativeClimate({t:\(t),h:\(l.h),mv:\(l.mv)})")
    }

    private func sendStatus(_ text: String) {
        let safe = text.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "'", with: "’")
        runJS("window.evNativeClimate&&window.evNativeClimate({status:'\(safe)'})")
    }

    private func runJS(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
