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

    /**
     * Runs of ordinary prose become one Text, not one per block.
     *
     * Selection lives inside a single Text view, so drawing every paragraph and list
     * item as its own made a message selectable only one paragraph at a time — which
     * looked like a bug in the bubble rather than in the renderer, because the bubble
     * is one bubble. Headings, paragraphs, lists and quotes are all expressible as
     * attributed text, so they are joined into one; only tables and code blocks, which
     * genuinely cannot live inside a Text, break the run.
     */
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(runs(of: MarkdownBlock.parse(text)).enumerated()), id: \.offset) { _, run in
                switch run {
                case .prose(let attributed):
                    Text(attributed)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .block(let block):
                    view(for: block)
                }
            }
        }
    }

    private enum Run {
        case prose(AttributedString)
        case block(MarkdownBlock)
    }

    /// Groups everything that can be attributed text, leaving the rest standing alone.
    private func runs(of blocks: [MarkdownBlock]) -> [Run] {
        var out: [Run] = []
        var pending: [AttributedString] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var joined = AttributedString()
            for (index, piece) in pending.enumerated() {
                if index > 0 { joined += AttributedString("\n\n") }
                joined += piece
            }
            out.append(.prose(joined))
            pending = []
        }

        for block in blocks {
            switch block {
            case .table, .code:
                flush()
                out.append(.block(block))
            default:
                if let piece = attributed(for: block) { pending.append(piece) }
            }
        }
        flush()
        return out
    }

    /// One block as attributed text, carrying its own size and weight.
    private func attributed(for block: MarkdownBlock) -> AttributedString? {
        switch block {
        case .paragraph(let text):
            var piece = Self.attributed(text)
            piece.font = .system(size: 14.5)
            return piece

        case .heading(let level, let text):
            var piece = Self.attributed(text)
            piece.font = .system(size: headingSize(level), weight: .semibold)
            return piece

        case .quote(let text):
            var piece = Self.attributed(text)
            piece.font = .system(size: 14.5).italic()
            return piece

        case .list(let items, let ordered):
            var piece = AttributedString()
            for (index, item) in items.enumerated() {
                if index > 0 { piece += AttributedString("\n") }
                var marker = AttributedString(ordered ? "\(index + 1). " : "•  ")
                marker.foregroundColor = .secondary
                piece += marker
                piece += Self.attributed(item)
            }
            piece.font = .system(size: 14.5)
            return piece

        case .rule:
            var piece = AttributedString("———")
            piece.foregroundColor = .secondary
            return piece

        case .table, .code:
            return nil
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

        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
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
    case table(header: [String], rows: [[String]])

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

            /**
             * A table, before anything else gets to it.
             *
             * Rows look like ordinary text, and a paragraph joins its lines with a
             * space — so a well-formed table arrived as one long run of pipes. Detected
             * by the separator underneath the header, which is the part that makes a
             * table a table rather than a line that happens to contain a pipe.
             */
            if isTableRow(trimmed), let next = lines.first, isTableSeparator(next) {
                flush()
                lines = lines.dropFirst()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                while let row = lines.first, isTableRow(row.trimmingCharacters(in: .whitespaces)) {
                    lines = lines.dropFirst()
                    rows.append(tableCells(row.trimmingCharacters(in: .whitespaces)))
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

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

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && line.filter { $0 == "|" }.count >= 2
    }

    /// The `|---|:--:|` line under a header. Without it, pipes are just punctuation.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard isTableRow(trimmed) else { return false }
        return tableCells(trimmed).allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { ":-".contains($0) }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// A markdown table, as an actual table.
///
/// Scrolls sideways rather than wrapping cells: a price next to a probability is only
/// useful while the row still reads as a row, and a bot comparing five bets across five
/// columns is exactly when that matters.
private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(cell(header, column))
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(MarkdownText.attributed(cell(row, column)))
                                .font(.system(size: 12.5))
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cell(_ row: [String], _ column: Int) -> String {
        column < row.count ? row[column] : ""
    }
}
