import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The install one-liner, shown wherever a person with no core will actually read it:
/// the setup step that asks for one, and the screen a later launch lands on when the
/// core has gone away.
///
/// Copyable, because the whole point of a one-liner is not retyping it, and with a
/// way to open Terminal, because the person reading this may never have. The screen
/// underneath keeps trying the port, so the moment the installer finishes, it moves on
/// by itself.
struct InstallCommand: View {
    static let command = "curl -fsSL https://raw.githubusercontent.com/narralabs/routi/main/scripts/install.sh | sh"
    @State private var copied = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // Wraps rather than truncates: a command with its middle cut out is
                // one nobody can retype, and the copy button is not the only way in.
                Text(Self.command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(copied ? "Copied" : "Copy") { copy() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background.secondary, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator, lineWidth: 0.5) }

            #if os(macOS)
            Button("Copy and Open Terminal") {
                copy()
                let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                NSWorkspace.shared.openApplication(at: terminal, configuration: .init())
            }
            .controlSize(.small)
            #endif
        }
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.command, forType: .string)
        #else
        UIPasteboard.general.string = Self.command
        #endif
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}
