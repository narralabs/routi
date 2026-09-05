import SwiftUI

/// Renders the desktop's latest frame, optionally forwarding input back to it.
///
/// Coordinates are converted from the view's own geometry into the desktop's pixel
/// space, so a click lands where the user aimed regardless of how the frame is scaled
/// — the rail thumbnail and the full-size window share this one implementation.
struct ScreenView: View {
    let frame: Data?
    let size: CGSize
    var isInteractive = false
    var onInput: ([String: Any]) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.black.opacity(0.9))

                if let frame, let image = decode(frame) {
                    image
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .contentShape(.rect)
            .onTapGesture { location in
                guard isInteractive else { return }
                if let point = desktopPoint(from: location, in: proxy.size) {
                    onInput(["kind": "click", "x": point.x, "y": point.y])
                }
            }
        }
    }

    /// Maps a point in the view onto the desktop, accounting for the letterboxing
    /// `aspectRatio(contentMode: .fit)` introduces.
    private func desktopPoint(from location: CGPoint, in viewSize: CGSize) -> (x: Int, y: Int)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(viewSize.width / size.width, viewSize.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(
            x: (viewSize.width - drawn.width) / 2,
            y: (viewSize.height - drawn.height) / 2
        )
        let local = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        guard local.x >= 0, local.y >= 0, local.x <= drawn.width, local.y <= drawn.height else {
            return nil  // clicked the letterbox, not the screen
        }
        return (Int(local.x / scale), Int(local.y / scale))
    }

    private func decode(_ data: Data) -> Image? {
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}
