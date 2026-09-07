import SwiftUI

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var selectedProvider = "anthropic"

    /// The chosen provider's own models. Ids do not cross providers.
    private var providerModels: [ModelInfo] { model.models(for: selectedProvider) }

    private var canHaveScreen: Bool { model.supportsScreen(selectedProvider) }

    /// Says plainly when a provider cannot drive a screen, rather than offering one
    /// that would be created and never reached.
    private var screenFootnote: String {
        canHaveScreen
            ? surfaceMode.explanation
            : "\(ProviderInfo.find(selectedProvider).name) runs its own agent, which does not take Routi's browser tools yet, so a bot here cannot use a screen."
    }
    @State private var selectedModel = "default"
    // Defaults to a screen, and an isolated one. A bot without a screen can only talk,
    // and "a bot that does things" is the whole premise; a bot on the real desktop is
    // a deliberate choice, not a default.
    @State private var surfaceMode = SurfaceMode.container
    @State private var isSubmitting = false

    var body: some View {
        SheetScaffold(title: "New Bot", confirmLabel: "Create", canConfirm: !name.isEmpty && !isSubmitting) {
            VStack(alignment: .leading, spacing: 18) {
                FormField("Name") {
                    TextField("", text: $name, prompt: Text("Research Bot"))
                        .textFieldStyle(.roundedBorder)
                }

                FormField(
                    "Description",
                    footnote: "What this bot does, and how it should go about it. This is the bot's whole identity — it introduces itself from this, and works from it."
                ) {
                    TextField(
                        "",
                        text: $systemPrompt,
                        prompt: Text("Finds hotels and flights. Knows travel deals cold, and always checks the cancellation terms."),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)
                }

                FormField(
                    "Provider",
                    footnote: "Fixed once the bot is created. Connect more under Settings → Providers."
                ) {
                    ProviderRows(connected: model.availableProviders, selection: $selectedProvider)
                }

                FormField(
                    "Model",
                    footnote: "Model and effort can be changed any time, from the line under the message box."
                ) {
                    Picker("", selection: $selectedModel) {
                        ForEach(providerModels) { info in
                            Text(info.presentedName(in: providerModels)).tag(info.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(providerModels.isEmpty)
                }

                FormField("Screen", footnote: screenFootnote) {
                    Picker("", selection: $surfaceMode) {
                        ForEach(SurfaceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                    .disabled(!canHaveScreen)

            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The default is Anthropic by habit; a person who connected something
            // else should not open on a provider with no models in it.
            .onAppear {
                if !model.availableProviders.contains(selectedProvider),
                   let first = model.availableProviders.first {
                    selectedProvider = first
                }
            }
            .onChange(of: selectedProvider) { _, new in
                // A provider that cannot drive a screen should not appear to offer one.
                if !model.supportsScreen(new) { surfaceMode = .none }
                // Only a connected provider can be chosen; snap back if the user
                // reaches an unconfigured entry via the keyboard.
                if !model.availableProviders.contains(new) {
                    selectedProvider = model.availableProviders.first ?? "anthropic"
                    return
                }
                // Model ids do not cross providers, so the choice cannot survive the
                // switch — take the new provider's first.
                selectedModel = providerModels.first?.id ?? "default"
            }
        } onConfirm: {
            isSubmitting = true
            Task {
                await model.createBot(
                    name: name,
                    systemPrompt: systemPrompt,
                    provider: selectedProvider,
                    model: selectedModel,
                    effort: nil,
                    surfaceMode: surfaceMode
                )
                dismiss()
            }
        } onCancel: {
            dismiss()
        }
        .onAppear {
            if !model.availableProviders.contains(selectedProvider) {
                selectedProvider = model.availableProviders.first ?? "anthropic"
            }
            if let first = providerModels.first, !providerModels.contains(where: { $0.id == selectedModel }) {
                selectedModel = first.id
            }
            if !canHaveScreen { surfaceMode = .none }
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
    @State private var selectedModel: String
    @State private var selectedEffort: Effort

    private var canHaveScreen: Bool { model.supportsScreen(bot.provider) }

    /// The bot's own provider's models. Ids do not cross providers, and neither does
    /// a bot — so the provider is the one thing this sheet does not offer to change.
    private var providerModels: [ModelInfo] { model.models(for: bot.provider) }

    private var availableEfforts: [Effort] {
        let levels = providerModels.first { $0.id == selectedModel }?.effortLevels ?? []
        return levels.compactMap(Effort.init(rawValue:))
    }
    private var supportsEffort: Bool { !availableEfforts.isEmpty }

    /// A bot's provider is fixed, so this is a statement about the bot rather than a
    /// choice: when its harness will not take Routi's browser tools, a screen here
    /// would be created and never reached.
    private var screenFootnote: String {
        canHaveScreen
            ? surfaceMode.explanation
            : "\(ProviderInfo.find(bot.provider).name) runs its own agent, which does not take Routi's browser tools yet, so this bot cannot use a screen."
    }

    init(bot: Bot) {
        self.bot = bot
        _name = State(initialValue: bot.name)
        _systemPrompt = State(initialValue: bot.systemPrompt)
        _surfaceMode = State(initialValue: bot.surfaceMode)
        _selectedModel = State(initialValue: bot.model)
        _selectedEffort = State(initialValue: Effort.parse(bot.effort))
    }

    var body: some View {
        SheetScaffold(title: "Bot Settings", confirmLabel: "Save", canConfirm: !name.isEmpty) {
            VStack(alignment: .leading, spacing: 18) {
                FormField("Name") {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                FormField("Description", footnote: "What this bot does, and how it should go about it.") {
                    TextField("", text: $systemPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(4...10)
                }

                FormField(
                    "Model",
                    footnote: "Changing it keeps the conversation; the next reply comes from the new model."
                ) {
                    Picker("", selection: $selectedModel) {
                        ForEach(providerModels) { info in
                            Text(info.presentedName(in: providerModels)).tag(info.id)
                        }
                        // A model the list no longer carries still needs a row, or the
                        // picker would silently show the wrong one as current.
                        if !providerModels.contains(where: { $0.id == bot.model }) {
                            Text(bot.model).tag(bot.model)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(providerModels.isEmpty)
                }

                if supportsEffort {
                    FormField("Effort", footnote: selectedEffort.detail) {
                        Picker("", selection: $selectedEffort) {
                            ForEach(availableEfforts) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                FormField("Screen", footnote: screenFootnote) {
                    Picker("", selection: $surfaceMode) {
                        ForEach(SurfaceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!canHaveScreen)
                }

            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await model.loadModels(for: bot.provider) }
            .onChange(of: selectedModel) {
                // A level the new model does not accept would be rejected on the
                // first turn; land on one it does.
                if supportsEffort, !availableEfforts.contains(selectedEffort) {
                    selectedEffort = availableEfforts.contains(.implicitDefault) ? .implicitDefault : availableEfforts[0]
                }
            }
        } onConfirm: {
            Task {
                var patch: [String: Any] = [
                    "name": name,
                    "systemPrompt": systemPrompt,
                    "surfaceMode": surfaceMode.rawValue,
                    "model": selectedModel,
                ]
                // Nil clears: a model with no levels hands effort back to the provider.
                patch["effort"] = supportsEffort ? selectedEffort.rawValue : NSNull()
                await model.updateBot(bot.id, patch: patch)
                dismiss()
            }
        } onCancel: {
            dismiss()
        }
    }
}

/// The connected providers, one row each, with the line that tells them apart.
///
/// Only what has a credential: an unconnected provider is not a choice here, it is a
/// trip to Settings, and eight chips in one row — most of them disabled, all of them
/// truncated — said nothing a person could act on. A row has room for the icon, the
/// name, and the one line that says who runs the bot and what pays for it, which is
/// the actual decision when more than one is connected.
private struct ProviderRows: View {
    /// Connected provider ids, in roster order.
    let connected: [String]
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 6) {
            ForEach(connected, id: \.self) { id in
                let provider = ProviderInfo.find(id)
                ProviderRow(provider: provider, isSelected: id == selection) { selection = id }
            }
            if connected.isEmpty {
                Text("No provider is connected yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderInfo
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.10) }
        if isHovering { return Color.primary.opacity(0.05) }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ProviderIcon(provider: provider, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    Text(provider.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(shape.fill(fill))
            .overlay(shape.stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: isSelected ? 1.5 : 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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

            // Scrolls rather than clips: the form grows when a model exposes effort
            // levels, and a fixed-height sheet silently cut the last field off.
            ScrollView {
                content.padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)

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
        .frame(width: 540, height: 660)
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
