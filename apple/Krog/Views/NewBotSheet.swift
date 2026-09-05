import SwiftUI

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var selectedProvider = "anthropic"
    @State private var selectedModel = "default"
    @State private var isSubmitting = false

    var body: some View {
        SheetScaffold(title: "New Bot", confirmLabel: "Create", canConfirm: !name.isEmpty && !isSubmitting) {
            VStack(alignment: .leading, spacing: 18) {
                FormField("Name") {
                    TextField("", text: $name, prompt: Text("Research Bot"))
                        .textFieldStyle(.roundedBorder)
                }

                FormField("Personality") {
                    TextField(
                        "",
                        text: $systemPrompt,
                        prompt: Text("You are a sharp research assistant. Be concise."),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)
                }

                HStack(alignment: .top, spacing: 14) {
                    FormField("Provider") {
                        Picker("", selection: $selectedProvider) {
                            ForEach(ProviderInfo.all) { provider in
                                // Unavailable providers stay visible but unselectable —
                                // the roster is the roadmap, and hiding them would imply
                                // Anthropic is the only one ever planned.
                                Text(provider.isAvailable ? provider.name : "\(provider.name) — Soon")
                                    .tag(provider.id)
                            }
                        }
                        .labelsHidden()
                    }

                    FormField("Model", footnote: "Fixed once the bot is created.") {
                        Picker("", selection: $selectedModel) {
                            ForEach(model.models) { info in
                                Text(info.displayName).tag(info.id)
                            }
                        }
                        .labelsHidden()
                        .disabled(model.models.isEmpty)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: selectedProvider) { _, new in
                // Only a configured provider can be chosen; snap back if the user
                // reaches a "Soon" entry via the keyboard.
                if !ProviderInfo.find(new).isAvailable { selectedProvider = "anthropic" }
            }
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
            VStack(alignment: .leading, spacing: 18) {
                FormField("Name") {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                FormField("Personality") {
                    TextField("", text: $systemPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(4...10)
                }

                FormField("Screen", footnote: surfaceMode.explanation) {
                    Picker("", selection: $surfaceMode) {
                        ForEach(SurfaceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// Label above its control, both left aligned.
///
/// macOS `Form` puts the label in a right-aligned leading column and the control
/// beside it, which reads as a settings inspector rather than a creation form. Stacking
/// gives every field the full sheet width and one consistent left edge.
struct FormField<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder let content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            content
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 10)
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
