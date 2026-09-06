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
            : "\(ProviderInfo.find(selectedProvider).name) runs its own agent, which does not take Krog's browser tools yet, so a bot here cannot use a screen."
    }
    @State private var selectedModel = "default"
    @State private var selectedEffort = Effort.implicitDefault
    // Defaults to a screen. A bot without one can only talk, and "a bot that does
    // things" is the whole premise — defaulting to none quietly produced bots that
    // could only offer to help.
    @State private var surfaceMode = SurfaceMode.container
    @State private var isSubmitting = false

    /// Only offer the levels the chosen model actually accepts — Haiku, for one,
    /// reports none, and a picker of options the API would reject is worse than none.
    private var availableEfforts: [Effort] {
        let levels = providerModels.first { $0.id == selectedModel }?.effortLevels ?? []
        return levels.compactMap(Effort.init(rawValue:))
    }

    private var supportsEffort: Bool { !availableEfforts.isEmpty }

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

                FormField("Provider") {
                    ProviderChips(connected: Set(model.availableProviders), selection: $selectedProvider)
                }

                FormField("Model") {
                    Picker("", selection: $selectedModel) {
                        ForEach(providerModels) { info in
                            Text(info.displayName).tag(info.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(providerModels.isEmpty)
                }

                if supportsEffort {
                    FormField(
                        "Effort",
                        footnote: "\(selectedEffort.detail) Provider, model and effort are fixed once the bot is created."
                    ) {
                        Picker("", selection: $selectedEffort) {
                            ForEach(availableEfforts) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                } else {
                    Text("Provider and model are fixed once the bot is created.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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
                    effort: supportsEffort ? selectedEffort : nil,
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

    private var canHaveScreen: Bool { model.supportsScreen(bot.provider) }

    /// A bot's provider is fixed, so this is a statement about the bot rather than a
    /// choice: when its harness will not take Krog's browser tools, a screen here
    /// would be created and never reached.
    private var screenFootnote: String {
        canHaveScreen
            ? surfaceMode.explanation
            : "\(ProviderInfo.find(bot.provider).name) runs its own agent, which does not take Krog's browser tools yet, so this bot cannot use a screen."
    }

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

                FormField("Description", footnote: "What this bot does, and how it should go about it.") {
                    TextField("", text: $systemPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(4...10)
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

/// A single row of provider chips: drawn icon beside the name.
///
/// A `Picker` menu can't show these — macOS menu items render only `Text` and `Image`,
/// so the provider tiles (a filled shape with a mark) would be dropped. Chips also
/// keep every option visible at a glance, which is the point of showing the roster.
private struct ProviderChips: View {
    /// Which providers have a working credential right now. A provider that exists as
    /// an adapter but is not connected reads as "Connect in Settings" rather than as a
    /// choice, because picking it would make a bot that cannot answer.
    let connected: Set<String>
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ProviderInfo.all) { provider in
                ProviderChip(
                    provider: provider,
                    isConnected: connected.contains(provider.id),
                    isSelected: provider.id == selection,
                    action: { if connected.contains(provider.id) { selection = provider.id } }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderChip: View {
    let provider: ProviderInfo
    let isConnected: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    // Concrete types throughout: an `if`-branching `some ShapeStyle` here pushed the
    // expression past the type-checker's budget.
    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        if isHovering && isConnected { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var stroke: Color {
        isSelected ? Color.accentColor : Color.primary.opacity(0.12)
    }

    private var helpText: String {
        if isConnected { return "\(provider.name) · \(provider.models)" }
        return provider.isAvailable
            ? "\(provider.name) — connect it in Settings first"
            : "\(provider.name) — not yet available"
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
        .opacity(isConnected ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    private var label: some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: provider, size: 18)
            Text(provider.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(shape.fill(fill))
        .overlay(shape.stroke(stroke, lineWidth: isSelected ? 1.5 : 0.5))
        .contentShape(.rect)
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
        .frame(width: 540, height: 560)
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
