import SwiftUI
import WebKit

/// The full FreshRSS web interface, embedded in the popover.
///
/// This is the "just show me the real thing" mode. It is off by default because
/// it reintroduces exactly what the project exists to remove: a scrolling page.
/// The native list answers "is there anything for me" without offering anything
/// to scroll through; this does not.
///
/// Nonetheless it is genuinely useful — for subscribing to a new feed, or for
/// reading a long article without leaving the menu bar.
struct WebViewPane: NSViewRepresentable {

    let url: URL?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // .default() (not .nonPersistent()) so the FreshRSS session cookie
        // survives; without it the user would log in on every single open.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // NOTE: deliberately not using the `setValue(false, forKey: "drawsBackground")`
        // trick to make the web view transparent. That is private API reached
        // through KVC, and an unrecognised key raises NSUnknownKeyException at
        // runtime — a crash, not a graceful degradation. FreshRSS has its own
        // theme, so its background is the correct thing to show anyway.

        if let url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard let url else { return }
        // Only reload when the target actually changed. Reloading on every
        // SwiftUI update would reset the page on each background refresh.
        if webView.url?.absoluteString != url.absoluteString, webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebViewPane

        init(_ parent: WebViewPane) {
            self.parent = parent
        }

        /// Keep the embedded pane on the FreshRSS origin; send everything else to
        /// the real browser.
        ///
        /// Without this, a click on an article link would navigate the *panel*
        /// away from FreshRSS, and the menu bar would be showing a news site with
        /// no way back.
        ///
        /// The closure must be spelled `@escaping @MainActor @Sendable` to match
        /// the protocol requirement exactly. A plain `@escaping` closure silently
        /// satisfies nothing, and the delegate call is never made.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Non-http schemes (mailto:, etc.) always go to the system.
            guard target.scheme == "http" || target.scheme == "https" else {
                if navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(target)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
                return
            }

            let homeHost = parent.url?.host
            let isSameHost = target.host == homeHost

            // A user-clicked link that leaves FreshRSS goes to the browser.
            if navigationAction.navigationType == .linkActivated && !isSameHost {
                NSWorkspace.shared.open(target)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
