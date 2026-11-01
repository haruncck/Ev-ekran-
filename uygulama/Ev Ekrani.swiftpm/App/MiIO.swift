import Foundation
import Network
import CryptoKit
import CommonCrypto

/// Xiaomi Mi Home devices on the home network (robot vacuum, lamps, purifiers…), spoken to directly with the
/// local miIO protocol: UDP port 54321, AES-128-CBC with the device's 32-hex-digit token. No cloud.
///
/// Page → app: {cmd:"miio", id, ip, token, method, params}
/// App → page: {type:"miio", id, ok, result?, error?}
final class MiIO {
    private let bridge: Bridge
    private let queue = DispatchQueue(label: "evekrani.miio")
    private var nextId: Int

    init(bridge: Bridge) {
        self.bridge = bridge
        let saved = UserDefaults.standard.integer(forKey: "miioNextId")
        nextId = saved > 0 ? saved : Int(Date().timeIntervalSince1970) % 100_000 + 1000
    }

    func request(_ body: [String: Any]) {
        let id = body["id"] as? String ?? ""
        guard let ip = body["ip"] as? String, LocalHTTP.isPrivate(ip),
              let tokenText = body["token"] as? String, let token = MiIO.hexData(tokenText), token.count == 16,
              let method = body["method"] as? String else {
            bridge.send(["type": "miio", "id": id, "ok": false, "error": "Eksik ya da hatalı adres/anahtar"])
            return
        }
        let params = body["params"] ?? []
        nextId += 1
        if nextId > 9_000_000 { nextId = 1000 }
        UserDefaults.standard.set(nextId, forKey: "miioNextId")
        let messageId = nextId
        queue.async { [weak self] in
            self?.run(id: id, ip: ip, token: token, messageId: messageId, method: method, params: params)
        }
    }

    // MARK: - Protocol

    private func run(id: String, ip: String, token: Data, messageId: Int, method: String, params: Any) {
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: 54321, using: .udp)
        connection.start(queue: queue)
        defer { connection.cancel() }

        // 1) hello: learn the device id and its clock
        var hello = Data([0x21, 0x31, 0x00, 0x20])
        hello.append(Data(repeating: 0xFF, count: 28))
        guard let reply = exchange(connection, hello, timeout: 4), reply.count >= 32 else {
            fail(id, "Cihaz cevap vermedi (adres doğru mu, cihaz açık mı?)")
            return
        }
        let deviceId = reply.subdata(in: 8..<12)
        let stamp = reply.subdata(in: 12..<16).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        // 2) the command
        let payloadObject: [String: Any] = ["id": messageId, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(payloadObject),
              let json = try? JSONSerialization.data(withJSONObject: payloadObject, options: []),
              let encrypted = MiIO.aes(json, token: token, encrypt: true) else {
            fail(id, "Komut hazırlanamadı")
            return
        }
        var header = Data([0x21, 0x31])
        let length = UInt16(32 + encrypted.count)
        header.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xFF)])
        header.append(contentsOf: [0, 0, 0, 0])
        header.append(deviceId)
        let ts = stamp &+ 1
        header.append(contentsOf: [UInt8(ts >> 24 & 0xFF), UInt8(ts >> 16 & 0xFF), UInt8(ts >> 8 & 0xFF), UInt8(ts & 0xFF)])
        let checksum = MiIO.md5(header + token + encrypted)
        let packet = header + checksum + encrypted

        guard let answer = exchange(connection, packet, timeout: 6), answer.count > 32 else {
            fail(id, "Cihaz komutu cevaplamadı (anahtar yanlış olabilir)")
            return
        }
        guard var plain = MiIO.aes(answer.subdata(in: 32..<answer.count), token: token, encrypt: false) else {
            fail(id, "Cevap çözülemedi (anahtar yanlış olabilir)")
            return
        }
        while let last = plain.last, last == 0 { plain.removeLast() }
        guard let object = try? JSONSerialization.jsonObject(with: plain, options: []) as? [String: Any] else {
            fail(id, "Cevap okunamadı")
            return
        }
        var message: [String: Any] = ["type": "miio", "id": id, "ok": object["error"] == nil]
        if let result = object["result"] { message["result"] = result }
        if let error = object["error"] { message["error"] = error }
        bridge.send(message)
    }

    /// Send one datagram and wait for one answer (runs on the private queue).
    private func exchange(_ connection: NWConnection, _ data: Data, timeout: TimeInterval) -> Data? {
        let done = DispatchSemaphore(value: 0)
        var received: Data?
        connection.send(content: data, completion: .contentProcessed { _ in })
        connection.receiveMessage { content, _, _, _ in
            received = content
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return received
    }

    private func fail(_ id: String, _ text: String) {
        bridge.send(["type": "miio", "id": id, "ok": false, "error": text])
    }

    // MARK: - Crypto helpers

    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    static func aes(_ input: Data, token: Data, encrypt: Bool) -> Data? {
        let key = md5(token)
        let iv = md5(key + token)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress,
                                inBytes.baseAddress, input.count,
                                outBytes.baseAddress, outputCapacity,
                                &moved)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        output.count = moved
        return output
    }

    static func hexData(_ text: String) -> Data? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count % 2 == 0 else { return nil }
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
