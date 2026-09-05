import SwiftUI

/// One turn. Blocks render as siblings so a tool card can sit between two
/// paragraphs, exactly as the daemon streamed them.
struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let startsGroup: Bool

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                ForEach(message.blocks) { block in
                    blockView(block)
                }
            }
            /**
             * Copy lives here rather than on hover, and copies whole things rather than
             * whatever was dragged over.
             *
             * Selection cannot cross bubbles: SwiftUI selects within one Text view, and
             * every message is its own, so dragging down a thread appears to select and
             * then copies without the structure. Rather than pretend otherwise, this
             * offers the two units anyone actually wants — this message, or the lot.
             */
            .contextMenu {
                if !copyableText.isEmpty {
                    Button("Copy Message", systemImage: "doc.on.doc") {
                        copyToPasteboard(copyableText)
                    }
                }
                Button("Copy Conversation", systemImage: "doc.on.doc.fill") {
                    copyToPasteboard(model.transcript())
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
        // 4pt read as one bubble with a seam in it: two grey bubbles that close
        // together look like a single message that happens to have a gap. A group still
        // gets much more, so the two levels stay tellable apart.
        .padding(.top, startsGroup ? 20 : 9)
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

    private var copyableText: String {
        message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct Bubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let isUser: Bool

    /// The outgoing bubble tracks `primary`, so its label must be the opposite.
    private var outgoingText: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        // Outgoing messages are typed by hand and short, so they render as written.
        // Replies are structured — headings, lists, tables of prices — and go through
        // the block renderer.
        Group {
            if isUser {
                Text(MarkdownText.attributed(text)).font(.system(size: 14.5))
            } else {
                MarkdownText(text: text)
            }
        }
            .lineSpacing(2)
            .foregroundStyle(isUser ? AnyShapeStyle(outgoingText) : AnyShapeStyle(.primary))
            // Selection is enabled on the text itself: a run of prose is one Text view,
            // and that is the unit a selection can cover.
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isUser ? AnyShapeStyle(Color.bubbleOutgoing) : AnyShapeStyle(Color.bubbleIncoming),
                in: .rect(cornerRadius: 18, style: .continuous)
            )
            .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)
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
///
/// Detail is one line, and only opens on request. Providers put wildly different
/// things in a tool's detail — a search phrase, a URL, or an entire `/bin/bash -lc`
/// invocation — and a transcript that pastes the last of those in full stops being
/// something a person can read. What a bot is *doing* stays visible; how it is doing
/// it waits until someone asks.
struct ToolCard: View {
    let tool: Block.ToolUse
    @State private var isExpanded = false

    /// Whether there is more to see than the single line already shown.
    private var isMultiline: Bool {
        guard let title = tool.title else { return false }
        return title != ToolLabel.oneLine(title)
    }

    private var status: (String, Color) {
        switch tool.status {
        case .running: return ("Running", .accentColor)
        case .done: return ("Done", .green)
        case .error: return ("Failed", .red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: ToolLabel.icon(for: tool.name))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
                Text(ToolLabel.title(for: tool.name))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    Circle().fill(status.1).frame(width: 6, height: 6)
                    Text(status.0)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(status.1)
                }
            }
            if let title = tool.title, !title.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Text(isExpanded ? title : ToolLabel.oneLine(title))
                            .font(.system(size: 12, design: isExpanded ? .monospaced : .default))
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 1)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if isMultiline {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!isMultiline)
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

    /// The user's bubble is near-black in the reference, not the accent colour.
    /// Defined against `primary` so it inverts to near-white in dark mode.
    static let bubbleOutgoing = Color.primary.opacity(0.92)
}

func copyToPasteboard(_ string: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #else
    UIPasteboard.general.string = string
    #endif
}

/// What a tool call is called in front of a person.
///
/// The wire names are plumbing — `mcp__desktop__click` says where a tool is registered
/// and by whom, none of which is the user's business. A bot driving a browser should
/// read as doing recognisable things.
enum ToolLabel {
    private static let known: [String: (title: String, icon: String)] = [
        "mcp__desktop__screenshot": ("Looking at the screen", "eye"),
        "mcp__desktop__open_url": ("Opening a page", "safari"),
        "mcp__desktop__click": ("Clicking", "cursorarrow.click"),
        "mcp__desktop__type_text": ("Typing", "keyboard"),
        "mcp__desktop__press_key": ("Pressing a key", "keyboard"),
        "mcp__desktop__scroll": ("Scrolling", "arrow.up.arrow.down"),
        "WebSearch": ("Searching the web", "magnifyingglass"),
        "WebFetch": ("Reading a page", "doc.text"),
        "Read": ("Reading a file", "doc.text"),
        "Write": ("Writing a file", "square.and.pencil"),
        "Edit": ("Editing a file", "square.and.pencil"),
        "Bash": ("Running a command", "terminal"),
        "Glob": ("Finding files", "folder"),
        "Grep": ("Searching files", "magnifyingglass"),
        "Task": ("Working on a sub-task", "arrow.triangle.branch"),
        "TodoWrite": ("Updating its plan", "checklist"),
    ]

    static func title(for name: String) -> String { known[name]?.title ?? prettify(name) }

    /// A tool's detail reduced to something that fits on one line.
    ///
    /// Shell invocations are the reason this exists: a provider that reports a command
    /// reports the whole thing, newlines and quoting and all. The first meaningful line
    /// says what it was, and the rest waits behind the chevron.
    static func oneLine(_ detail: String) -> String {
        let stripped = detail
            .replacingOccurrences(of: "^/bin/(ba)?sh -lc [\"']?", with: "", options: .regularExpression)
        let firstLine = stripped
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? stripped

        let limit = 68
        guard firstLine.count > limit else {
            return firstLine == detail ? detail : firstLine
        }
        return String(firstLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
    static func icon(for name: String) -> String { known[name]?.icon ?? "wrench.and.screwdriver" }

    /// Fallback for a tool nobody has named yet: strip the MCP routing prefix and
    /// space out the identifier, so a new tool reads as words rather than as code.
    private static func prettify(_ name: String) -> String {
        var base = name
        if base.hasPrefix("mcp__"), let last = base.components(separatedBy: "__").last {
            base = last
        }
        base = base.replacingOccurrences(of: "_", with: " ")
        base = base.replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression
        )
        return base.prefix(1).uppercased() + base.dropFirst().lowercased()
    }
}
