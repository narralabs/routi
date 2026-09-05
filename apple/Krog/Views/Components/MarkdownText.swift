import SwiftUI

/// Renders an assistant message as markdown.
///
/// `AttributedString(markdown:)` alone was doing this, and it only ever parses *inline*
/// syntax — bold, italic, links, code spans. Everything structural passed through as
/// literal text, so a reply that opened with `## GE Profile` showed the hashes. This
/// walks the block level itself and hands each block's text back to `AttributedString`
/// for the inline work, which is the part it does well.
///
/// Deliberately not a full CommonMark implementation: it covers what a chat reply
/// actually contains — headings, lists, code fences, quotes, rules, paragraphs — and
/// anything unrecognised falls through as a paragraph rather than being mangled.
struct MarkdownText: View {
    let text: String
    var textColor: AnyShapeStyle = AnyShapeStyle(.primary)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, 2)

        case .paragraph(let text):
            inline(text).font(.system(size: 14.5))

        case .quote(let text):
            inline(text)
                .font(.system(size: 14.5))
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 2)
                }

        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: 14.5))
                            .foregroundStyle(.secondary)
                            // A fixed gutter keeps the text edges aligned no matter
                            // how wide the marker is.
                            .frame(width: ordered ? 18 : 10, alignment: .trailing)
                        inline(item).font(.system(size: 14.5))
                    }
                }
            }

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8, style: .continuous))

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func inline(_ source: String) -> Text {
        Text(Self.attributed(source))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 17
        case 3: return 15.5
        default: return 14.5
        }
    }

    static func attributed(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

/// One structural piece of a message.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
    case list(items: [String], ordered: Bool)
    case code(String)
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(items: listItems, ordered: listOrdered))
            listItems = []
        }
        func flush() { flushParagraph(); flushList() }

        var lines = source.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A fence runs to its closing fence, or to the end if the message is still
            // streaming and the close has not arrived yet.
            if trimmed.hasPrefix("```") {
                flush()
                var body: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                if lines.first != nil { lines = lines.dropFirst() }
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flush(); continue }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }

            if let hashes = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes.upperBound) - 1
                blocks.append(.heading(level: level, text: String(trimmed[hashes.upperBound...])))
                continue
            }

            if trimmed.hasPrefix("> ") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }

            if let marker = trimmed.range(of: "^[-*+] ", options: .regularExpression) {
                flushParagraph()
                if listOrdered { flushList() }
                listOrdered = false
                listItems.append(String(trimmed[marker.upperBound...]))
                continue
            }

            if let marker = trimmed.range(of: "^[0-9]{1,3}[.)] ", options: .regularExpression) {
                flushParagraph()
                if !listOrdered { flushList() }
                listOrdered = true
                listItems.append(String(trimmed[marker.upperBound...]))
                continue
            }

            flushList()
            paragraph.append(trimmed)
        }

        flush()
        return blocks
    }
}
