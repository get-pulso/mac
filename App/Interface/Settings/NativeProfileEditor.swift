import SwiftUI

struct NativeProfileEditor: View {
    // MARK: Internal

    @ObservedObject var model: NativeSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                photo
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        field("First name", text: $model.firstName, id: .firstName, placeholder: "First name")
                            .disabled(!model.attributeEnabled("first_name"))
                        field("Last name", text: $model.lastName, id: .lastName, placeholder: "Optional")
                            .disabled(!model.attributeEnabled("last_name"))
                    }
                    if model.attributeEnabled("username") {
                        field("Username", text: $model.username, id: .username, placeholder: "Your username")
                    }
                    field("Location", text: $model.location, id: .location, placeholder: "City or region · Optional")
                }
                about
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Links").font(.system(size: 13, weight: .semibold))
                        Text("Optional. Shown on your profile.").font(.callout).foregroundStyle(.secondary)
                    }
                    field("Website", text: $model.website, id: .website, placeholder: "example.com")
                    HStack(alignment: .top, spacing: 12) {
                        field("X", text: $model.twitter, id: .twitter, placeholder: "@username")
                        field("Telegram", text: $model.telegram, id: .telegram, placeholder: "@username")
                    }
                    Text("You can also paste a profile link.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(model.busy)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
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
            PulsoAvatar(url: session.user?.imageUrl, name: model.firstName, size: 52)
                .overlay {
                    if model.isRunning("upload-photo") {
                        Circle().fill(.regularMaterial)
                        NativeProgress(label: "Uploading photo")
                    }
                }
            Button(action: model.choosePhoto) {
                NativeAsyncButtonLabel(
                    title: "Change photo…",
                    loadingTitle: "Uploading…",
                    isLoading: model.isRunning("upload-photo")
                )
            }
            .nativeSettingsActionButton()
            Spacer(minLength: 0)
        }
    }

    private var about: some View {
        ProfileAboutField(text: $model.bio, focusedField: $focusedField)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.error { NativeInlineError(message: error) }
                HStack(spacing: 8) {
                    Text(model.hasProfileChanges ? "Unsaved changes" : model.notice ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Cancel") { model.navigate(.account) }
                        .nativeSettingsActionButton()
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.busy)
                    Button(action: save) {
                        NativeAsyncButtonLabel(
                            title: "Save changes", loadingTitle: "Saving…", isLoading: model.isRunning("save-profile")
                        )
                    }
                    .nativeSettingsPrimaryButton()
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.hasProfileChanges || model.busy)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.background(.bar)
    }

    private func field(
        _ title: String,
        text: Binding<String>,
        id: ProfileDraft.Field,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.medium)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .focused($focusedField, equals: id)
                .accessibilityLabel(title)
            if let error = model.profileDraft.errors[id], submitted || touched.contains(id) {
                fieldError(error)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
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
