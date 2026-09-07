import SwiftUI

/// One note, in full, to correct or remove.
///
/// Notes are written by bots during conversation, so nowhere lists them with fields to
/// type into: the rail and Settings show them, and a click brings one here. The same
/// sheet takes a new fact in Settings, the one place a person writes a note themselves.
struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let title: String
    /// Nil when writing a new note; `onCreate` then says where it goes.
    let memory: Memory?
    var onCreate: ((String) async -> Void)? = nil

    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var provenance: String? {
        guard let memory else { return nil }
        let when = Date(timeIntervalSince1970: memory.updatedAt / 1000)
            .formatted(.dateTime.month(.abbreviated).day().year())
        return memory.source == "user" ? "Edited by you, \(when)" : "Noted by the bot, \(when)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 110)
                .background(.background.secondary, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.separator, lineWidth: 0.5)
                }
                .focused($focused)

            if let provenance {
                Text(provenance)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                if let memory {
                    Button("Delete", role: .destructive) {
                        Task {
                            await model.deleteMemory(memory.id)
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || trimmed == memory?.text)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            text = memory?.text ?? ""
            focused = true
        }
    }

    private func save() {
        let value = trimmed
        guard !value.isEmpty else { return }
        Task {
            if let memory {
                await model.updateMemory(memory.id, value)
            } else {
                await onCreate?(value)
            }
            dismiss()
        }
    }
}
