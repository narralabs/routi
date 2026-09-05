import SwiftUI

/// Building blocks for the settings screen.
///
/// The layout is the one every modern settings pane uses: a quiet section header, then
/// a rounded card of rows, each row a title plus explanation on the left and a control
/// on the right. Written by hand rather than with `Form`, because `Form`'s grouped
/// style puts the control and its description on separate lines and can't do the
/// two-line-label-plus-trailing-control shape.

struct SettingsSection<Content: View>: View {
    let title: String?
    /// A line under the group, for saying what the rows are rather than what they say.
    let footnote: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content
            }
            .background(.background.secondary, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator.opacity(0.5), lineWidth: 0.5)
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One row. `Divider` is drawn by the row itself so cards don't need separator logic.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var isFirst = false
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider().padding(.leading, 14)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }
}

/// Read-only value, styled to line up with the interactive controls beside it.
struct SettingsValue: View {
    let text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Page title + scrolling body, shared by every pane.
struct SettingsPane<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.bottom, 2)
                content
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
    }
}
