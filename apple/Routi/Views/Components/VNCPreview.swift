#if DEBUG
import SwiftUI
import WebKit

/// Opt-in local experiment. No effect in Release or without -vncPreviewURL.
#if os(macOS)
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
#else
struct VNCCursor {
    let image: UIImage
    let hotspot: CGPoint
}

struct VNCPreview: UIViewRepresentable {
    let url: URL
    var onCursor: (VNCCursor?) -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onCursor: (VNCCursor?) -> Void
        init(onCursor: @escaping (VNCCursor?) -> Void) { self.onCursor = onCursor }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let png = body["png"] as? String, png.count <= 400_000,
                  let data = Data(base64Encoded: png), let image = UIImage(data: data),
                  image.size.width > 0, image.size.width <= 256,
                  image.size.height > 0, image.size.height <= 256,
                  let x = body["hotx"] as? Double, let y = body["hoty"] as? Double,
                  x >= 0, x < image.size.width, y >= 0, y < image.size.height
            else { onCursor(nil); return }
            onCursor(VNCCursor(image: image, hotspot: CGPoint(x: x, y: y)))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCursor: onCursor) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "cursor")
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Native TouchLayer handles gestures, including the black margins.
        view.isUserInteractionEnabled = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCursor = onCursor
        if view.url != url { view.load(URLRequest(url: url)) }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "cursor")
        view.evaluateJavaScript("window.disconnectVNC?.()")
        view.loadHTMLString("", baseURL: nil)
    }
}
#endif
#endif
