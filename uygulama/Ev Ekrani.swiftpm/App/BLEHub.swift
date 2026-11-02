import Foundation
import CoreBluetooth

/// All Bluetooth work for the home screen (contract: uygulama/KOPRU.md).
///  - thermometers (Xiaomi LYWSD03MMC): one short connection every 5 minutes, one notification read
///  - plant sensors (Xiaomi Mi Flora): one connection every 30 minutes
///  - presence tags (any device the page marks as "tag"): only listened to (6 s every 45 s), never connected
///  - discovery scans for the page's "Cihaz ara"
/// The page decides which devices exist; with no list yet the first LYWSD03 heard is read (app v1 behaviour).
final class BLEHub: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let bridge: Bridge
    private var central: CBCentralManager!

    private let thermoService = CBUUID(string: "EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let thermoReading = CBUUID(string: "EBE0CCC1-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let floraService = CBUUID(string: "00001204-0000-1000-8000-00805F9B34FB")
    private let floraMode = CBUUID(string: "00001A00-0000-1000-8000-00805F9B34FB")
    private let floraData = CBUUID(string: "00001A01-0000-1000-8000-00805F9B34FB")
    private let floraFirmware = CBUUID(string: "00001A02-0000-1000-8000-00805F9B34FB")

    private struct Wanted {
        let id: UUID
        let kind: String
    }

    private var wanted: [Wanted] = []
    private var autoThermo: UUID?
    private let autoKey = "sensorIdentifier"

    private var peripherals: [UUID: CBPeripheral] = [:]
    private var names: [UUID: String] = [:]
    private var rssis: [UUID: Int] = [:]
    private var tagSentAt: [UUID: Date] = [:]
    private var due: [UUID: Date] = [:]
    private var lastThermo: [UUID: [String: Any]] = [:]

    private var current: CBPeripheral?
    private var currentKind = ""
    private var floraBattery = -1
    private var floraDataChar: CBCharacteristic?
    private var floraFirmwareChar: CBCharacteristic?
    private var giveUp: Timer?
    private var ticker: Timer?

    private var scanEnd: Date?
    private var scanFound: [UUID: [String: Any]] = [:]
    private var scanReport: Timer?

    init(bridge: Bridge) {
        self.bridge = bridge
        super.init()
        if let saved = UserDefaults.standard.string(forKey: autoKey) {
            autoThermo = UUID(uuidString: saved)
        }
        central = CBCentralManager(delegate: self, queue: nil)
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pump()
            self?.manageScan()
        }
    }

    // MARK: - Commands from the page

    func handle(_ body: [String: Any]) {
        guard let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "devices":
            let list = body["list"] as? [[String: Any]] ?? []
            var next: [Wanted] = []
            for item in list {
                guard let text = item["id"] as? String,
                      let id = UUID(uuidString: text),
                      let kind = item["kind"] as? String else { continue }
                next.append(Wanted(id: id, kind: kind))
            }
            wanted = next
            if central.state == .poweredOn {
                retrieveWanted()
            }
            pump()
        case "scan":
            let seconds = (body["seconds"] as? Double) ?? 20
            scanFound = [:]
            scanEnd = Date().addingTimeInterval(max(5, min(60, seconds)))
            scanReport?.invalidate()
            scanReport = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.reportScan()
            }
            startScanning()
        default:
            break
        }
    }

    /// After the page (re)loads, give it the latest readings again.
    func resendLatest() {
        for (_, message) in lastThermo {
            bridge.send(message)
        }
        if let primary = primaryThermo(), let message = lastThermo[primary] {
            sendV1(message)
        }
    }

    private func primaryThermo() -> UUID? {
        if let first = wanted.first(where: { $0.kind == "thermo" }) {
            return first.id
        }
        return wanted.isEmpty ? autoThermo : nil
    }

    // MARK: - Scanning (in short bursts, to save battery)
    //
    // Thermometers and plant sensors are connected to directly by identifier, so they need no scanning.
    // Scanning runs continuously only during a "Cihaz ara" discovery or until the first thermometer is
    // adopted (at most 10 minutes after start); with presence tags it runs about 5 s out of every 45 s (the page counts someone as gone only
    // after 10 minutes without a sighting). Otherwise the radio stays quiet.

    private var burstStart = Date.distantPast
    private let burstEvery: TimeInterval = 45
    private let burstLength: TimeInterval = 4   // checked every 5 s, so a burst lasts about 5 s
    private let startedAt = Date()

    private func manageScan() {
        guard central.state == .poweredOn else { return }
        let now = Date()
        let discovering = scanEnd.map { now < $0 } ?? false
        let adopting = wanted.isEmpty && autoThermo == nil && now.timeIntervalSince(startedAt) < 600
        let hasTags = wanted.contains { $0.kind == "tag" }
        let missing = wanted.contains { ($0.kind == "thermo" || $0.kind == "flora") && peripherals[$0.id] == nil }
        var want = discovering || adopting
        if !want && (hasTags || missing) {
            if now.timeIntervalSince(burstStart) >= burstEvery { burstStart = now }
            want = now.timeIntervalSince(burstStart) < burstLength
        }
        if want && !central.isScanning {
            // Duplicates only while discovering (live signal strength in the list); a fresh burst reports each device once.
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: discovering])
        } else if !want && central.isScanning {
            central.stopScan()
        }
    }

    private func startScanning() {
        guard central.state == .poweredOn else { return }
        if central.isScanning { central.stopScan() }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func reportScan() {
        let done = scanEnd.map { Date() >= $0 } ?? true
        let list = Array(scanFound.values).sorted { a, b in
            ((a["rssi"] as? Int) ?? -200) > ((b["rssi"] as? Int) ?? -200)
        }
        bridge.send(["type": "scan", "devices": list, "done": done])
        if done {
            scanReport?.invalidate()
            scanReport = nil
            scanEnd = nil
            manageScan()
        }
    }

    static func kind(for name: String) -> String {
        let n = name.lowercased()
        if n.hasPrefix("lywsd03") || n.hasPrefix("atc_") || n.hasPrefix("mjwsd") { return "thermo" }
        if n.hasPrefix("flower care") || n.hasPrefix("flower mate") { return "flora" }
        if n.hasPrefix("itag") || n.hasPrefix("smart tag") || n.hasPrefix("tag") { return "tag" }
        return "other"
    }

    // MARK: - Reading queue (one connection at a time)

    private func pump() {
        prune()
        guard central.state == .poweredOn, current == nil else { return }
        let now = Date()
        var targets: [(UUID, String)] = wanted
            .filter { $0.kind == "thermo" || $0.kind == "flora" }
            .map { ($0.id, $0.kind) }
        if wanted.isEmpty, let auto = autoThermo {
            targets = [(auto, "thermo")]
        }
        for (id, kind) in targets {
            if let when = due[id], when > now { continue }
            let known = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
            guard let peripheral = known else { continue }
            peripherals[id] = peripheral
            read(peripheral, kind: kind)
            return
        }
    }

    private func read(_ peripheral: CBPeripheral, kind: String) {
        current = peripheral
        currentKind = kind
        floraBattery = -1
        floraDataChar = nil
        floraFirmwareChar = nil
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        giveUp?.invalidate()
        giveUp = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            self?.finish(success: false)
        }
    }

    private func finish(success: Bool) {
        giveUp?.invalidate()
        guard let peripheral = current else { return }
        let isFlora = currentKind == "flora"
        current = nil
        currentKind = ""
        if peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        let wait: TimeInterval = success ? (isFlora ? 1800 : 300) : (isFlora ? 120 : 60)
        due[peripheral.identifier] = Date().addingTimeInterval(wait)
        if !success {
            let name = names[peripheral.identifier] ?? peripheral.name ?? "Sensör"
            bridge.send([
                "type": "status",
                "id": peripheral.identifier.uuidString,
                "text": "\(name) okunamadı, birazdan yeniden denenecek"
            ])
        }
    }

    /// Phones and other devices change their Bluetooth identity often: forget strangers so memory stays flat.
    private func prune() {
        guard names.count > 400 || rssis.count > 400 else { return }
        let keep = Set(wanted.map { $0.id } + (autoThermo.map { [$0] } ?? []))
        names = names.filter { keep.contains($0.key) }
        rssis = rssis.filter { keep.contains($0.key) }
        tagSentAt = tagSentAt.filter { keep.contains($0.key) }
        peripherals = peripherals.filter { keep.contains($0.key) || $0.value == current }
    }

    private func retrieveWanted() {
        let ids = wanted.map { $0.id }
        guard !ids.isEmpty else { return }
        for peripheral in central.retrievePeripherals(withIdentifiers: ids) {
            peripherals[peripheral.identifier] = peripheral
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            retrieveWanted()
            pump()
            manageScan()
        case .unauthorized:
            bridge.send(["type": "status", "text": "Bluetooth izni yok: Ayarlar › Gizlilik › Bluetooth"])
        case .poweredOff:
            bridge.send(["type": "status", "text": "Bluetooth kapalı"])
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertised ?? peripheral.name ?? names[id] ?? ""
        let rssi = RSSI.intValue
        let kind = BLEHub.kind(for: name)
        let isWanted = wanted.contains(where: { $0.id == id })
        let scanning = scanEnd.map { Date() < $0 } ?? false

        if isWanted || kind == "thermo" || kind == "flora" || scanning {
            if !name.isEmpty { names[id] = name }
            if rssi < 0 { rssis[id] = rssi }
        }
        if peripherals[id] == nil && (isWanted || kind == "thermo" || kind == "flora") {
            peripherals[id] = peripheral
        }

        // No list from the page yet: adopt the first thermometer heard (app v1 behaviour).
        if wanted.isEmpty && autoThermo == nil && kind == "thermo" {
            autoThermo = id
            UserDefaults.standard.set(id.uuidString, forKey: autoKey)
            pump()
        }

        // Presence tag: report that it is around, at most every 20 seconds.
        if let entry = wanted.first(where: { $0.id == id }), entry.kind == "tag" {
            let now = Date()
            let recent = tagSentAt[id].map { now.timeIntervalSince($0) < 20 } ?? false
            if !recent {
                tagSentAt[id] = now
                bridge.send(["type": "seen", "id": id.uuidString, "kind": "tag", "name": name, "rssi": rssi])
            }
        }

        // Discovery for the page's device list.
        if scanning && !name.isEmpty {
            scanFound[id] = ["id": id.uuidString, "name": name, "kind": kind, "rssi": rssi]
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == current else { return }
        peripheral.discoverServices([currentKind == "flora" ? floraService : thermoService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral == current { finish(success: false) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral == current { finish(success: false) }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == current else { return }
        let wantedService = currentKind == "flora" ? floraService : thermoService
        guard let service = peripheral.services?.first(where: { $0.uuid == wantedService }) else {
            finish(success: false)
            return
        }
        if currentKind == "flora" {
            peripheral.discoverCharacteristics([floraMode, floraData, floraFirmware], for: service)
        } else {
            peripheral.discoverCharacteristics([thermoReading], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == current else { return }
        let characteristics = service.characteristics ?? []
        if currentKind == "flora" {
            floraDataChar = characteristics.first(where: { $0.uuid == floraData })
            floraFirmwareChar = characteristics.first(where: { $0.uuid == floraFirmware })
            if let mode = characteristics.first(where: { $0.uuid == floraMode }) {
                // Newer Mi Flora firmware only gives live data after this "read now" command.
                peripheral.writeValue(Data([0xA0, 0x1F]), for: mode, type: .withResponse)
            } else if let firmware = floraFirmwareChar {
                peripheral.readValue(for: firmware)
            } else {
                finish(success: false)
            }
        } else {
            guard let reading = characteristics.first(where: { $0.uuid == thermoReading }) else {
                finish(success: false)
                return
            }
            peripheral.setNotifyValue(true, for: reading)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == current, characteristic.uuid == floraMode else { return }
        if let firmware = floraFirmwareChar {
            peripheral.readValue(for: firmware)
        } else if let data = floraDataChar {
            peripheral.readValue(for: data)
        } else {
            finish(success: false)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == current, let value = characteristic.value else { return }
        let b = [UInt8](value)
        let id = peripheral.identifier
        let name = names[id] ?? peripheral.name ?? ""
        let rssi = rssis[id] ?? 0

        if characteristic.uuid == thermoReading {
            guard b.count >= 3 else { return }
            let raw = Int16(bitPattern: UInt16(b[0]) | (UInt16(b[1]) << 8))
            let t = Double(raw) / 100.0
            let h = Int(b[2])
            let mv = b.count >= 5 ? Int(UInt16(b[3]) | (UInt16(b[4]) << 8)) : 0
            guard t > -30, t < 70, h <= 100 else { return }
            let message: [String: Any] = [
                "type": "reading", "id": id.uuidString, "kind": "thermo", "name": name,
                "t": round2(t), "h": h, "mv": mv, "rssi": rssi
            ]
            lastThermo[id] = message
            bridge.send(message)
            if id == primaryThermo() { sendV1(message) }
            finish(success: true)
        } else if characteristic.uuid == floraFirmware {
            if b.count >= 1 { floraBattery = Int(b[0]) }
            if let data = floraDataChar {
                peripheral.readValue(for: data)
            } else {
                finish(success: false)
            }
        } else if characteristic.uuid == floraData {
            guard b.count >= 10, !(b[0] == 0xAA && b[1] == 0xBB) else {
                finish(success: false)
                return
            }
            let t = Double(Int16(bitPattern: UInt16(b[0]) | (UInt16(b[1]) << 8))) / 10.0
            let light = Int(UInt32(b[3]) | (UInt32(b[4]) << 8) | (UInt32(b[5]) << 16) | (UInt32(b[6]) << 24))
            let moisture = Int(b[7])
            let conductivity = Int(UInt16(b[8]) | (UInt16(b[9]) << 8))
            bridge.send([
                "type": "reading", "id": id.uuidString, "kind": "flora", "name": name,
                "t": round2(t), "moisture": moisture, "light": light, "cond": conductivity,
                "bat": floraBattery, "rssi": rssi
            ])
            finish(success: true)
        }
    }

    // MARK: - Helpers

    private func round2(_ v: Double) -> Double {
        (v * 100).rounded() / 100
    }

    /// Pages from before the device list (index.html v63) only know window.evNativeClimate.
    private func sendV1(_ message: [String: Any]) {
        guard let t = message["t"] as? Double, let h = message["h"] as? Int else { return }
        let mv = message["mv"] as? Int ?? 0
        let text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), t)
        bridge.run("window.evNativeClimate&&window.evNativeClimate({t:\(text),h:\(h),mv:\(mv)})")
    }
}
