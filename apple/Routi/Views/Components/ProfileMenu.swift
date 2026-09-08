import SwiftUI

/// The menu behind the profile's name, wherever it appears: switch to another
/// profile or make one, and open Settings. Clicking the name used to open Settings
/// outright; now that a person can have several profiles the name is the way between
/// them, and Settings is one row down.
struct ProfileMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Section(model.userName) {
                Menu("Switch Profile") {
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
                    Divider()
                    Button("New Profile…") { model.isShowingNewProfile = true }
                }
                Button("Settings…") { model.isShowingSettings = true }
            }
        } label: {
            label()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Profile menu")
        .accessibilityIdentifier("profileMenu")
    }
}

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
            FormField(
                "Name",
                footnote: "A profile keeps its own bots and its own accounts. Sign in to Claude, ChatGPT or Grok for this one under Settings after it is made."
            ) {
                TextField("", text: $name, prompt: Text("William (Narra Labs)"))
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
