import Foundation

/// Lets the page talk to devices on the home network (TV, lamps…), which a web page itself cannot do
/// (mixed content, self-signed certificates, digest login), and read public HTTPS sources that do not allow
/// browser requests (CORS). A device's own self-signed certificate is accepted only on private addresses.
///
/// Page → app: {cmd:"http", id, url, method?, headers?, body?, user?, pass?, timeout?}
/// App → page: {type:"http", id, ok, status, body, error?}
final class LocalHTTP: NSObject, URLSessionTaskDelegate {
    private let bridge: Bridge
    private var session: URLSession!
    private var credentials: [Int: URLCredential] = [:]

    init(bridge: Bridge) {
        self.bridge = bridge
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    static func isPrivate(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") { return true }
        if h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("169.254.") { return true }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), second >= 16 && second <= 31 { return true }
        }
        return false
    }

    func request(_ body: [String: Any]) {
        let id = body["id"] as? String ?? ""
        // Home-network devices on any scheme; public sites only over normal, fully checked HTTPS.
        guard let text = body["url"] as? String,
              let url = URL(string: text),
              let host = url.host,
              LocalHTTP.isPrivate(host) || url.scheme?.lowercased() == "https" else {
            bridge.send(["type": "http", "id": id, "ok": false, "status": 0, "body": "", "error": "Geçersiz adres"])
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = max(2, min(30, (body["timeout"] as? Double) ?? 10))
        request.httpMethod = (body["method"] as? String) ?? "GET"
        if let headers = body["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let payload = body["body"] as? String {
            request.httpBody = payload.data(using: .utf8)
        }
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            var reply: [String: Any] = [
                "type": "http", "id": id,
                "ok": error == nil && status >= 200 && status < 300,
                "status": status, "body": text
            ]
            if let error = error {
                reply["error"] = error.localizedDescription
            }
            self.bridge.send(reply)
        }
        if let user = body["user"] as? String, let pass = body["pass"] as? String {
            credentials[task.taskIdentifier] = URLCredential(user: user, password: pass, persistence: .forSession)
        }
        task.resume()
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let method = space.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust,
           LocalHTTP.isPrivate(space.host),
           let trust = space.serverTrust {
            // TVs and lamps use self-signed certificates; accept them on the home network only.
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodHTTPBasic {
            if challenge.previousFailureCount == 0, let credential = credentials[task.taskIdentifier] {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        credentials[task.taskIdentifier] = nil
    }
}
