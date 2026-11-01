import SwiftUI
import UIKit
import WebKit

/// Lets the page talk to the app without the web view keeping the coordinator alive forever.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// The home screen web app, full screen, with sound allowed without a tap first.
struct HomeWebView: UIViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = WKWebsiteDataStore.default()

        // Tells the page what this app can do (uygulama/KOPRU.md).
        let marker = WKUserScript(
            source: "window.EV_NATIVE={climate:true,app:'2',ble:true,brightness:true,battery:true,sound:true};",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(marker)
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "ev")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator

        model.bridge.webView = web
        web.load(URLRequest(url: homeURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let model: AppModel
        private var retry: Timer?

        init(model: AppModel) {
            self.model = model
        }

        // After every (re)load, give the page the latest readings straight away.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.hub.resendLatest()
            model.battery.push()
        }

        // Messages from the page: window.webkit.messageHandlers.ev.postMessage({cmd: ...}).
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
            switch cmd {
            case "brightness":
                if let value = body["value"] as? Double {
                    UIScreen.main.brightness = CGFloat(max(0.01, min(1.0, value)))
                }
            case "battery":
                model.battery.push()
            case "listen":
                let on = (body["on"] as? Bool) ?? false
                model.sound.set(on: on, threshold: body["threshold"] as? Double)
            default:
                model.hub.handle(body)
            }
        }

        // No internet when the app starts: try again every 30 seconds.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            scheduleRetry(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            scheduleRetry(webView)
        }

        private func scheduleRetry(_ webView: WKWebView) {
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak webView] _ in
                guard let webView = webView else { return }
                if webView.url == nil {
                    webView.load(URLRequest(url: homeURL))
                } else {
                    webView.reload()
                }
            }
        }

        // The page's memory was reclaimed by iOS: load it again instead of showing a blank screen.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        // Links such as shortcuts://, tel: or maps open in their own apps.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = (url.scheme ?? "").lowercased()
            if !["http", "https", "about", "data", "blob", "file"].contains(scheme) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // target="_blank" / window.open: open in Safari.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return nil
        }

        // alert / confirm from the page, shown as normal iOS dialogs.
        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Tamam", style: .default) { _ in completionHandler() })
            if !present(alert, from: webView) { completionHandler() }
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Vazgeç", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "Tamam", style: .default) { _ in completionHandler(true) })
            if !present(alert, from: webView) { completionHandler(false) }
        }

        private func present(_ alert: UIAlertController, from view: UIView) -> Bool {
            var top = view.window?.rootViewController
            while let next = top?.presentedViewController { top = next }
            guard let host = top else { return false }
            host.present(alert, animated: true, completion: nil)
            return true
        }
    }
}
