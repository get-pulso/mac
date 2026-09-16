import SwiftUI

struct NativeProfileEditor: View {
    // MARK: Internal

    @ObservedObject var model: NativeSettingsModel

    var body: some View {
        NativeFormScreen {
            NativeFormRow("Photo", alignment: .center) { photo }
            field("First name", text: $model.firstName, id: .firstName, placeholder: "First name")
                .disabled(!model.attributeEnabled("first_name"))
            field("Last name", text: $model.lastName, id: .lastName, placeholder: "Optional")
                .disabled(!model.attributeEnabled("last_name"))
            if model.attributeEnabled("username") {
                field("Username", text: $model.username, id: .username, placeholder: "Your username")
            }
            field("Location", text: $model.location, id: .location, placeholder: "City or region · Optional")
            ProfileAboutField(text: $model.bio, focusedField: $focusedField)
            Divider().padding(.vertical, 4)
            field(
                "Website", text: $model.website, id: .website, placeholder: "example.com",
                hint: "Optional. Shown on your profile."
            )
            field("X", text: $model.twitter, id: .twitter, placeholder: "@username")
            field(
                "Telegram", text: $model.telegram, id: .telegram, placeholder: "@username",
                hint: "You can also paste a profile link."
            )
        } footer: {
            NativeFormFooter(error: model.error) {
                Button("Cancel") { model.navigate(.account) }
                    .nativeFormCancelButton()
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.busy)
                Spacer(minLength: 12)
                Button(action: save) {
                    NativeFormSubmitLabel(
                        title: "Save",
                        loadingTitle: "Saving…",
                        isLoading: model.isRunning("save-profile")
                    )
                }
                .nativeFormSubmitButton()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.hasProfileChanges || model.busy)
            }
        }
        .disabled(model.busy)
        .onChange(of: focusedField) { previous, _ in
            if let previous { touched.insert(previous) }
        }
    }

    // MARK: Private

    @ObservedObject private var session = NativeSession.shared
    @FocusState private var focusedField: ProfileDraft.Field?
    @State private var touched = Set<ProfileDraft.Field>()
    @State private var submitted = false

    private var photo: some View {
        HStack(spacing: 12) {
            FirstlightAvatar(url: session.user?.imageUrl, name: model.firstName, size: 44)
                .overlay {
                    if model.isRunning("upload-photo") {
                        Circle().fill(.regularMaterial)
                        NativeProgress(label: "Uploading photo")
                    }
                }
                .overlay { NativeSettingsAvatarBorder() }
            Button(action: model.choosePhoto) {
                NativeAsyncButtonLabel(
                    title: "Change photo…",
                    loadingTitle: "Uploading…",
                    isLoading: model.isRunning("upload-photo")
                )
            }
            .nativeSettingsActionButton()
        }
    }

    private func field(
        _ title: String,
        text: Binding<String>,
        id: ProfileDraft.Field,
        placeholder: String,
        hint: String? = nil
    ) -> some View {
        NativeFormRow(title) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .focused($focusedField, equals: id)
                .accessibilityLabel(title)
                .nativeFormField(focused: focusedField == id)
            if let error = model.profileDraft.errors[id], submitted || touched.contains(id) {
                NativeFormFieldError(message: error)
            } else if let hint {
                NativeFormHint(text: hint)
            }
        }
    }

    private func save() {
        self.submitted = true
        if let invalid = ProfileDraft.Field.allCases.first(where: { model.profileDraft.errors[$0] != nil }) {
            self.focusedField = invalid
            return
        }
        self.model.saveProfile()
    }
}
