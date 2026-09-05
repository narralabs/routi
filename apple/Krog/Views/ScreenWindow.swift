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
            Divider()
            ScreenView(
                frame: model.surfaceFrame,
                size: CGSize(width: model.surface.width, height: model.surface.height),
                pointer: model.surfacePointer,
                isInteractive: true,
                onInput: { input in Task { await model.sendSurfaceInput(input) } }
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
            Button {
                model.isShowingScreen = false
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            // Named for its bot: desktops are no longer shared between them.
            Text(model.selectedBot.map { "\($0.name)'s desktop" } ?? "Desktop")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Text("Click and type to drive it · Esc to leave")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
