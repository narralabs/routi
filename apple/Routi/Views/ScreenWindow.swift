import SwiftUI

/// The desktop at full window size.
///
/// Fills the app window rather than opening a sheet: a sheet is inset and dimmed
/// behind, which wastes the space the screen most needs, and a desktop you are driving
/// is a mode the whole window should be in.
struct ScreenWindow: View {
    @Environment(AppModel.self) private var model
    @State private var frameViewer = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            if let handover = model.handover(for: model.selectedBot?.id) {
                HandoverBanner(handover: handover)
            }
            Divider()
            ScreenView(
                frame: model.surfaceFrame,
                size: CGSize(width: model.surface.width, height: model.surface.height),
                isInteractive: true,
                onInput: { input in Task { await model.sendSurfaceInput(input) } },
                onPaste: { Task { await model.pasteIntoSurface() } },
                onCopy: { Task { await model.copyFromSurface() } }
            )
        }
        .background(.black.opacity(0.92))
        // A full-size view earns a faster refresh than the thumbnail did. It registers
        // as its own viewer, so leaving drops back to the panel's rate rather than
        // stopping the stream the panel is still using.
        .onAppear { model.beginFrames(frameViewer, interval: .milliseconds(120)) }
        .onDisappear { model.endFrames(frameViewer) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Named for its bot: desktops are no longer shared between them.
            Text(model.selectedBot.map { "\($0.name)'s desktop" } ?? "Desktop")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Text("Click and type to drive it")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            // Closing sits in the top right, the same corner the panel closes from, and
            // only there: every key, Escape included, belongs to the desktop, which
            // has dialogs and menus of its own for it to dismiss.
            CloseButton { model.isShowingScreen = false }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Matches the toolbar icons: nothing at rest, a soft fill under the pointer.
private struct CloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 6, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Close")
    }
}
