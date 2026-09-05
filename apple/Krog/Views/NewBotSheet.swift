import SwiftUI

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var selectedModel = "default"
    @State private var isSubmitting = false

    var body: some View {
        SheetScaffold(title: "New Bot", confirmLabel: "Create", canConfirm: !name.isEmpty && !isSubmitting) {
            Form {
                TextField("Name", text: $name, prompt: Text("Research Bot"))
                TextField(
                    "Personality",
                    text: $systemPrompt,
                    prompt: Text("You are a sharp research assistant. Be concise."),
                    axis: .vertical
                )
                .lineLimit(3...8)

                Picker("Model", selection: $selectedModel) {
                    ForEach(model.models) { info in
                        Text(info.displayName).tag(info.id)
                    }
                }
            }
            .formStyle(.grouped)
        } onConfirm: {
            isSubmitting = true
            Task {
                await model.createBot(name: name, systemPrompt: systemPrompt, model: selectedModel)
                dismiss()
            }
        } onCancel: {
            dismiss()
        }
        .onAppear {
            if let first = model.models.first, !model.models.contains(where: { $0.id == selectedModel }) {
                selectedModel = first.id
            }
        }
    }
}

struct BotSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let bot: Bot
    @State private var name: String
    @State private var systemPrompt: String
    @State private var surfaceMode: SurfaceMode

    init(bot: Bot) {
        self.bot = bot
        _name = State(initialValue: bot.name)
        _systemPrompt = State(initialValue: bot.systemPrompt)
        _surfaceMode = State(initialValue: bot.surfaceMode)
    }

    var body: some View {
        SheetScaffold(title: "Bot Settings", confirmLabel: "Save", canConfirm: !name.isEmpty) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Personality", text: $systemPrompt, axis: .vertical)
                        .lineLimit(4...10)
                }

                Section {
                    Picker("Screen", selection: $surfaceMode) {
                        ForEach(SurfaceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(surfaceMode.explanation)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } onConfirm: {
            Task {
                await model.updateBot(bot.id, patch: [
                    "name": name,
                    "systemPrompt": systemPrompt,
                    "surfaceMode": surfaceMode.rawValue,
                ])
                dismiss()
            }
        } onCancel: {
            dismiss()
        }
    }
}

/// Sheets need a title bar and buttons on macOS, where `.navigationTitle` and a
/// toolbar do not appear the way they do in an iOS sheet.
struct SheetScaffold<Content: View>: View {
    let title: String
    let confirmLabel: String
    let canConfirm: Bool
    @ViewBuilder let content: Content
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 16)
                .padding(.bottom, 8)
            content
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
            .padding(14)
        }
        .frame(width: 460, height: 420)
        #else
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmLabel, action: onConfirm).disabled(!canConfirm)
                    }
                }
        }
        #endif
    }
}
