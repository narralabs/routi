import SwiftUI

/// The menu behind the profile's name, wherever it appears: the profiles to switch
/// between, a new one, and Settings. Clicking the name used to open Settings
/// outright; now that a person can have several profiles the name is the way between
/// them, and Settings is one row down.
///
/// On the Mac it is a panel that opens upward from the name at the foot of the
/// sidebar, the way Grok Bot's does, rather than a system menu dropping below it and
/// off the bottom of the screen. On the phone it is the system menu, which is what a
/// thumb expects.
struct ProfileMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @ViewBuilder let label: () -> Label

    #if os(macOS)
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $isOpen, arrowEdge: .top) {
                ProfilePanel { isOpen = false }
            }
            .accessibilityLabel("Profile menu")
            .accessibilityIdentifier("profileMenu")
    }
    #else
    var body: some View {
        Menu {
            Section("Switch Profile") {
                Picker("Profile", selection: Binding(
                    get: { model.currentProfileID },
                    set: { id in Task { await model.switchProfile(to: id) } }
                )) {
                    ForEach(model.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Button { model.isShowingNewProfile = true } label: {
                    SwiftUI.Label("New Profile…", systemImage: "plus")
                }
            }
            Button { model.isShowingSettings = true } label: {
                SwiftUI.Label("Settings…", systemImage: "gearshape")
            }
            Section("Support") {
                Button { openURL(model.feedbackURL) } label: {
                    SwiftUI.Label("Give Feedback…", systemImage: "exclamationmark.bubble")
                }
            }
        } label: {
            label()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Profile menu")
        .accessibilityIdentifier("profileMenu")
    }
    #endif
}

#if os(macOS)
/// The panel: every profile with its initials and a check on the one showing, then
/// New Profile, then Settings. Rows highlight under the pointer like a menu's.
private struct ProfilePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Switch Profile")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            ForEach(model.profiles) { profile in
                PanelRow(title: profile.name, isCurrent: profile.id == model.currentProfileID) {
                    Text(AppModel.initials(of: profile.name))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: .circle)
                } action: {
                    dismiss()
                    Task { await model.switchProfile(to: profile.id) }
                }
            }

            PanelRow(title: "New Profile…") {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20)
            } action: {
                dismiss()
                model.isShowingNewProfile = true
            }

            Divider().padding(.vertical, 5).padding(.horizontal, 4)

            PanelRow(title: "Settings…") {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20)
            } action: {
                dismiss()
                model.isShowingSettings = true
            }

            Divider().padding(.vertical, 5).padding(.horizontal, 4)

            Text("Support")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

            // The issue form on GitHub, with the versions filled in. Everyone using
            // Routi this early knows their way around an issue; what they cannot be
            // expected to remember is which core they are on.
            PanelRow(title: "Give Feedback…") {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20)
            } action: {
                dismiss()
                openURL(model.feedbackURL)
            }
        }
        .padding(6)
        .frame(width: 250)
    }
}

private struct PanelRow<Leading: View>: View {
    let title: String
    var isCurrent = false
    @ViewBuilder let leading: Leading
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                leading
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: 6, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(title)
    }
}
#endif

/// Names a new profile. It starts empty: no bots, nothing connected. The person
/// connects an account for it under Settings, exactly as for the first.
struct NewProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSubmitting = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        SheetScaffold(title: "New Profile", confirmLabel: "Create", canConfirm: canCreate && !isSubmitting, height: 230) {
            // The hint is a kind of name, not a name: a real-looking one reads as
            // already filled in, and it is gone the moment typing starts, so what
            // the profile is for goes under the field where it stays.
            FormField(
                "Name",
                footnote: "What this profile is for: a company, a client, a side of your life. It keeps its own bots and its own accounts; sign in to Claude, ChatGPT or Grok for it under Settings once it is made."
            ) {
                TextField("", text: $name, prompt: Text("Work"))
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .accessibilityIdentifier("newProfileName")
                    .onSubmit { if canCreate { create() } }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { nameFocused = true }
        } onConfirm: {
            create()
        } onCancel: {
            dismiss()
        }
    }

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private func create() {
        isSubmitting = true
        Task {
            await model.createProfile(named: name)
            dismiss()
        }
    }
}
