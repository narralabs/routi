import SwiftUI
import WebKit

/// VNC display; native mobile gestures remain outside the web view.
#if os(macOS)
struct VNCView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    // DesktopViewer keys this view by URL, so navigation is only started once.
    func updateNSView(_ view: WKWebView, context: Context) {}

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

struct VNCView: UIViewRepresentable {
    let url: URL
    var onCursor: (VNCCursor?) -> Void
    var relayTrust: RelayTrust?

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var relayTrust: RelayTrust?
        var endpoint: URL?

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let relayTrust, challenge.protectionSpace.host == endpoint?.host,
                  challenge.protectionSpace.port == endpoint?.port else {
                completionHandler(.performDefaultHandling, nil); return
            }
            relayTrust.respond(to: challenge, completionHandler: completionHandler)
        }
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
        context.coordinator.endpoint = url
        context.coordinator.relayTrust = relayTrust
        view.navigationDelegate = context.coordinator
        // Native TouchLayer handles gestures, including the black margins.
        view.isUserInteractionEnabled = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCursor = onCursor
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "cursor")
        view.evaluateJavaScript("window.disconnectVNC?.()")
        view.loadHTMLString("", baseURL: nil)
    }
}
#endif

/// Resolves a fresh capability through the core whenever it reconnects.
struct DesktopViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let botID: String
    var interactive = true
    #if !os(macOS)
    var onCursor: (VNCCursor?) -> Void = { _ in }
    #endif
    @State private var url: URL?
    @State private var error: String?
    @State private var relayTrust: RelayTrust?
    @State private var retry = 0

    private var isVisible: Bool { scenePhase != .background }

    var body: some View {
        Group {
            if let url, isVisible {
                #if os(macOS)
                VNCView(url: url).id(url)
                #else
                VNCView(url: url, onCursor: onCursor, relayTrust: relayTrust).id(url)
                #endif
            } else if let error {
                VStack(spacing: 8) {
                    Text(error).font(.caption).multilineTextAlignment(.center)
                    Button("Retry") { retry += 1 }
                }.padding()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .task(id: "\(botID)-\(model.connection)-\(isVisible)-\(retry)") {
            url = nil; error = nil; relayTrust = nil
            guard isVisible else { return }
            do {
                let resolved = try await model.desktopViewerURL(botId: botID)
                guard !Task.isCancelled else { return }
                if let profile = model.relayViewerProfile {
                    relayTrust = try RelayTrust(certificate: profile.certificate, pkcs12: profile.pkcs12)
                }
                url = interactive ? resolved : resolved.appending(queryItems: [URLQueryItem(name: "viewOnly", value: "1")])
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
