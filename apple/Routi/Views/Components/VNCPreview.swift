#if os(macOS) && DEBUG
import SwiftUI
import WebKit

/// Opt-in local experiment. No effect in Release or without -vncPreviewURL.
struct VNCPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: ()) {
        view.evaluateJavaScript("window.disconnectVNC?.()")
        view.loadHTMLString("", baseURL: nil)
    }
}
#endif
