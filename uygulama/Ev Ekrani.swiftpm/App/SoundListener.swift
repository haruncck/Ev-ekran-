import Foundation
import AVFoundation
import SoundAnalysis
import Accelerate

/// Listens to the room with Apple's built-in on-device sound classifier (SoundAnalysis, iOS 15).
/// Nothing is recorded or sent anywhere: only the name of a recognised sound (e.g. "smoke_detector")
/// goes to the page, which decides what to do. Off until the page turns it on.
final class SoundListener: NSObject, SNResultsObserving {
    private let bridge: Bridge
    private let engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "evekrani.sound")
    private var wantOn = false
    private var running = false
    private var threshold = 0.6
    private var lastSent: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Only sounds whose name contains one of these are passed on.
    private let interesting = ["smoke", "fire", "alarm", "door", "knock", "baby", "cry", "glass", "shatter",
                               "dog", "bark", "siren", "beep", "bell", "scream", "water"]

    init(bridge: Bridge) {
        self.bridge = bridge
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.interrupted(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        })
    }

    func set(on: Bool, threshold newThreshold: Double?) {
        if let t = newThreshold {
            threshold = max(0.3, min(0.95, t))
        }
        wantOn = on
        if on {
            start()
        } else {
            stop(report: true)
        }
    }

    private func start() {
        guard !running else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.begin()
                } else {
                    self.bridge.send(["type": "listen", "on": false,
                                      "text": "Mikrofon izni yok: Ayarlar › Gizlilik › Mikrofon"])
                }
            }
        }
    }

    private func begin() {
        guard wantOn, !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // Keep the page's sounds and speech on the loudspeaker while listening.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                bridge.send(["type": "listen", "on": false, "text": "Mikrofon kullanılamıyor"])
                return
            }
            let newAnalyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // No overlapping windows: half the work of the default, still about one verdict a second.
            request.overlapFactor = 0
            try newAnalyzer.add(request, withObserver: self)
            analyzer = newAnalyzer

            input.removeTap(onBus: 0)
            let queue = analysisQueue
            // Battery: the classifier only runs while the room is not silent. A buffer louder than about
            // -50 dBFS opens the gate for 4 s (covers the pauses in an alarm's beep pattern); the buffer just
            // before it is analysed too, so the start of a sound is not lost.
            var openUntil: AVAudioFramePosition = 0
            var held: (AVAudioPCMBuffer, AVAudioFramePosition)?
            let hold = AVAudioFramePosition(format.sampleRate * 4)
            input.installTap(onBus: 0, bufferSize: 8192, format: format) { buffer, time in
                let pos = time.sampleTime
                var level: Float = 1
                if let ch = buffer.floatChannelData, buffer.frameLength > 0 {
                    vDSP_rmsqv(ch[0], 1, &level, vDSP_Length(buffer.frameLength))
                }
                let loud = level > 0.0032
                if loud { openUntil = pos + hold }
                if pos < openUntil {
                    let previous = held
                    held = nil
                    queue.async {
                        if let prev = previous { newAnalyzer.analyze(prev.0, atAudioFramePosition: prev.1) }
                        newAnalyzer.analyze(buffer, atAudioFramePosition: pos)
                    }
                } else {
                    held = (buffer, pos)
                }
            }
            engine.prepare()
            try engine.start()
            running = true
            bridge.send(["type": "listen", "on": true, "labels": request.knownClassifications])
        } catch {
            stop(report: false)
            bridge.send(["type": "listen", "on": false,
                         "text": "Ses tanıma başlatılamadı: \(error.localizedDescription)"])
        }
    }

    private func stop(report: Bool) {
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            analyzer?.removeAllRequests()
            analyzer = nil
            running = false
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        if report {
            bridge.send(["type": "listen", "on": false])
        }
    }

    private func restart() {
        guard wantOn else { return }
        stop(report: false)
        begin()
    }

    private func interrupted(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            stop(report: false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.restart()
            }
        }
    }

    // MARK: - SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        for item in classification.classifications.prefix(3) {
            let label = item.identifier.lowercased()
            let confidence = item.confidence
            guard confidence >= threshold, interesting.contains(where: { label.contains($0) }) else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.report(label, confidence)
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.restart()
        }
    }

    func requestDidComplete(_ request: SNRequest) {}

    private func report(_ label: String, _ confidence: Double) {
        let now = Date()
        if let last = lastSent[label], now.timeIntervalSince(last) < 8 { return }
        lastSent[label] = now
        bridge.send(["type": "sound", "label": label, "confidence": (confidence * 100).rounded() / 100])
    }
}
