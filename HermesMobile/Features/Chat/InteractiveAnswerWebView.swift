import SwiftUI
import WebKit

/// Hosts one interactive answer page. Pages keep nothing
/// between loads, cannot navigate anywhere, and reach the app only through
/// `InteractiveAnswerBridgeMessage`s.
struct InteractiveAnswerWebView: UIViewRepresentable {
    let html: String
    let onMessage: (InteractiveAnswerBridgeMessage) -> Void
    let onNavigationFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(
            WeakScriptMessageHandler(context.coordinator),
            name: InteractiveAnswerDocument.messageHandlerName
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.parent = self
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(html, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: InteractiveAnswerDocument.messageHandlerName
        )
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: InteractiveAnswerWebView?
        private var loadedHTML: String?

        /// Loads `html` unless it is already the page on screen.
        func load(_ html: String, in webView: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let decoded = InteractiveAnswerBridgeMessage.decode(message.body) else { return }
            parent?.onMessage(decoded)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // The page's own HTML string loads as about:blank; everything else
            // (links, redirects, form posts) stays put. Links open only through
            // the bridge, which requires a tap: `.linkActivated` is also set for
            // a script's `a.click()`, so opening here would bypass that gate.
            if navigationAction.navigationType == .other,
               navigationAction.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loadedHTML = nil
            parent?.onNavigationFailure()
        }

        private func reportFailure(_ error: Error) {
            // A navigation this delegate cancelled is not a failure.
            if (error as NSError).code == NSURLErrorCancelled { return }
            if (error as NSError).domain == "WebKitErrorDomain", (error as NSError).code == 102 { return }
            parent?.onNavigationFailure()
        }
    }
}

/// `WKUserContentController` retains its handlers; this breaks the cycle
/// through the coordinator.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
