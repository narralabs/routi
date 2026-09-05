import SwiftUI

/// One turn. Blocks render as siblings so a tool card can sit between two
/// paragraphs, exactly as the daemon streamed them.
struct MessageRow: View {
    let message: Message
    let startsGroup: Bool

    @State private var isHovering = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isUser { Spacer(minLength: 40); actions }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                ForEach(message.blocks) { block in
                    blockView(block)
                }
            }

            if !isUser { actions; Spacer(minLength: 40) }
        }
        .padding(.top, startsGroup ? 20 : 4)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .text(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Bubble(text: text, isUser: isUser)
            }
        case .thinking(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ThinkingDisclosure(text: text)
            }
        case .toolUse(let tool):
            ToolCard(tool: tool)
        case .image(let payload):
            ImageBlockView(payload: payload)
        case .toolResult, .surfaceEvent, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            Button("Copy", systemImage: "doc.on.doc") {
                copyToPasteboard(message.plainText)
            }
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct Bubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        // Markdown for free: AttributedString parses inline markdown, and Text
        // renders it with the system font's real bold and italic faces.
        Text(attributed)
            .font(.system(size: 14.5))
            .lineSpacing(2)
            .foregroundStyle(isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.bubbleIncoming),
                in: .rect(cornerRadius: 18, style: .continuous)
            )
            .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// Reasoning collapses by default; expanded it buries the actual answer.
private struct ThinkingDisclosure: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 540, alignment: .leading)
                .padding(.leading, 4)
                .padding(.top, 4)
        } label: {
            Label("Thought process", systemImage: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

/// The "Computer — Done" card from the reference app.
struct ToolCard: View {
    let tool: Block.ToolUse

    private var status: (String, Color) {
        switch tool.status {
        case .running: return ("Running", .accentColor)
        case .done: return ("Done", .green)
        case .error: return ("Failed", .red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(tool.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    Circle().fill(status.1).frame(width: 6, height: 6)
                    Text(status.0)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(status.1)
                }
            }
            if let title = tool.title {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 13, style: .continuous))
    }
}

private struct ImageBlockView: View {
    let payload: Block.ImagePayload

    var body: some View {
        if let image = decoded {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 380)
                .clipShape(.rect(cornerRadius: 13, style: .continuous))
        }
    }

    private var decoded: Image? {
        guard let dataURL = payload.dataURL,
              let base64 = dataURL.split(separator: ",").last,
              let data = Data(base64Encoded: String(base64))
        else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.tertiary)
                    .frame(width: 6, height: 6)
                    .offset(y: -2.5 * lift(i))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Color.bubbleIncoming, in: .rect(cornerRadius: 18, style: .continuous))
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func lift(_ index: Int) -> Double {
        let t = (phase - Double(index) * 0.16).truncatingRemainder(dividingBy: 1.0)
        let clamped = t < 0 ? t + 1 : t
        return clamped < 0.4 ? clamped / 0.4 : max(0, 1 - (clamped - 0.4) / 0.6)
    }
}

extension Color {
    /// Fill for incoming (assistant) bubbles.
    ///
    /// Defined as primary-at-low-opacity rather than a semantic material: the
    /// `.quaternary` style is nearly invisible against the chat canvas, which left
    /// assistant messages looking like they had no background at all. This reads
    /// clearly in both light and dark, because `primary` inverts with the scheme.
    static let bubbleIncoming = Color.primary.opacity(0.06)
}

func copyToPasteboard(_ string: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #else
    UIPasteboard.general.string = string
    #endif
}
