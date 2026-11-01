import SwiftUI
import UIKit
import WebKit

/// The home screen web app, full screen, with sound allowed without a tap first.
struct HomeWebView: UIViewRepresentable {
    let sensor: SensorReader

    func makeCoordinator() -> Coordinator {
        Coordinator(sensor: sensor)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = WKWebsiteDataStore.default()

        // Tells the page that the sensor is read by this app (see window.evNativeClimate in index.html).
        let marker = WKUserScript(
            source: "window.EV_NATIVE={climate:true,app:'1'};",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(marker)

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator

        sensor.webView = web
        web.load(URLRequest(url: homeURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let sensor: SensorReader
        private var retry: Timer?

        init(sensor: SensorReader) {
            self.sensor = sensor
        }

        // After every (re)load, give the page the latest reading straight away.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            sensor.pushLatest()
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
