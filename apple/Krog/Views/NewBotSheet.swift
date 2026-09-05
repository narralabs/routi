import SwiftUI

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var selectedProvider = "anthropic"
    @State private var selectedModel = "default"
    @State private var selectedEffort = Effort.implicitDefault
    @State private var isSubmitting = false

    /// Only offer the levels the chosen model actually accepts — Haiku, for one,
    /// reports none, and a picker of options the API would reject is worse than none.
    private var availableEfforts: [Effort] {
        let levels = model.models.first { $0.id == selectedModel }?.effortLevels ?? []
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

                FormField("Provider") {
                    ProviderChips(selection: $selectedProvider)
                }

                FormField("Model") {
                    Picker("", selection: $selectedModel) {
                        ForEach(model.models) { info in
                            Text(info.displayName).tag(info.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.models.isEmpty)
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
                await model.createBot(
                    name: name,
                    systemPrompt: systemPrompt,
                    model: selectedModel,
                    effort: supportsEffort ? selectedEffort : nil
                )
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
/// so the monogram tiles (a filled shape with a label) would be dropped. Chips also
/// keep every option visible at a glance, which is the point of showing the roster.
private struct ProviderChips: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ProviderInfo.all) { provider in
                ProviderChip(
                    provider: provider,
                    isSelected: provider.id == selection,
                    action: { selection = provider.id }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderChip: View {
    let provider: ProviderInfo
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    // Concrete types throughout: an `if`-branching `some ShapeStyle` here pushed the
    // expression past the type-checker's budget.
    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        if isHovering && provider.isAvailable { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var stroke: Color {
        isSelected ? Color.accentColor : Color.primary.opacity(0.12)
    }

    private var helpText: String {
        provider.isAvailable
            ? "\(provider.name) · \(provider.models)"
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
        .disabled(!provider.isAvailable)
        .opacity(provider.isAvailable ? 1 : 0.5)
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
