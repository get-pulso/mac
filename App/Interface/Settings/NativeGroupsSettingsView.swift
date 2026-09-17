import SwiftUI

struct NativeGroupsSettingsView: View {
    // MARK: Internal

    @ObservedObject var model: NativeGroupsModel
    let navigate: (NativeGroupsPage) -> Void

    var body: some View {
        Group {
            if !model.loaded, model.loading {
                Form { Section { NativeLabeledRowsSkeleton(rows: 4) } }
            } else if !model.loaded, let error = model.loadError {
                Form {
                    NativeStateMessage(
                        title: "Couldn't load groups",
                        message: error,
                        actionTitle: "Retry",
                        action: model.reload
                    )
                }
            } else {
                switch model.page {
                case .list: groupList
                case .create: createForm
                case .details: groupDetails
                case let .addMembers(id): addMembersForm(id)
                }
            }
        }
        .disabled(model.busy)
        .alert(confirmationTitle, isPresented: $confirming) {
            Button("Cancel", role: .cancel) { confirmationAction = nil }
            Button(confirmationButton, role: .destructive) { confirmationAction?(); confirmationAction = nil }
        } message: { Text(confirmationMessage) }
    }

    // MARK: Private

    @State private var confirming = false
    @State private var confirmationTitle = ""
    @State private var confirmationMessage = ""
    @State private var confirmationButton = "Remove"
    @State private var confirmationAction: (() -> Void)?

    /// Errors from the current operation and from a stale reload both belong
    /// in the footer, next to the action that will retry them.
    private var footerError: String? { self.model.error ?? (self.model.loaded ? self.model.loadError : nil) }

    private var groupList: some View {
        Form {
            Section {
                if model.groups.isEmpty {
                    Text("No groups yet. Create one to get started.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.groups) { group in
                        Button { navigate(.details(group.id)) } label: {
                            HStack(spacing: 12) {
                                Text(group.name).foregroundStyle(.primary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Text(group.is_creator == true ? "Owner" : "Member").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(group.name), \(group.is_creator == true ? "owner" : "member")")
                            .accessibilityHint("Open group settings")
                    }
                }
            }
            if let error = model.error { NativeInlineError(message: error) }
            if model.loaded, let error = model.loadError { NativeInlineError(message: error, retry: model.reload) }
        }
    }

    private var createForm: some View {
        NativeFormScreen {
            NativeFormRow("Name") {
                nameField
                NativeFormHint(text: "Only members can see activity in this group.")
            }
        } footer: {
            NativeFormFooter(error: footerError) {
                Button("Cancel") { navigate(.list) }
                    .nativeFormCancelButton()
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 12)
                submitButton("Create Group", loading: "Creating…", key: "create") {
                    model.create { navigate(.details($0)) }
                }.disabled(!model.validName)
            }
        }
    }

    @ViewBuilder private var groupDetails: some View {
        if let members = model.members {
            let owner = members.group.is_user_creator
            NativeFormScreen {
                NativeFormRow("Name") {
                    if owner { nameField } else { Text(members.group.name).padding(.vertical, 4) }
                }
                NativeFormRow("Invite link", alignment: .center) {
                    Button(action: model.copyInvite) {
                        NativeCopyButtonLabel(
                            title: "Copy invite link",
                            copied: model.copied,
                            loadingTitle: "Creating…",
                            isLoading: model.operation == "invite"
                        )
                    }
                    .nativeSettingsActionButton()
                    NativeFormHint(text: "Anyone with this link can join for 24 hours.")
                }
                NativeFormRow("Members") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(members.members.enumerated()), id: \.element.id) { index, person in
                            HStack(spacing: 10) {
                                FirstlightAvatar(url: person.avatar_url, name: person.displayName, size: 26)
                                Text(person.displayName).lineLimit(1)
                                Spacer(minLength: 8)
                                if person.is_creator == true {
                                    Text("Owner").font(.caption).foregroundStyle(.secondary)
                                } else if owner {
                                    Button {
                                        confirm(
                                            "Remove \(person.displayName)?",
                                            message: "They will no longer have access to this group.",
                                            button: "Remove"
                                        ) { model.removeMember(person) }
                                    } label: {
                                        NativeAsyncButtonLabel(
                                            title: "Remove…",
                                            loadingTitle: "Removing…",
                                            isLoading: model.operation == "remove-\(person.id)"
                                        )
                                    }
                                    .nativeSettingsActionButton().controlSize(.small)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            if index < members.members.count - 1 { Divider().padding(.leading, 46) }
                        }
                    }
                    .padding(.vertical, 2)
                    .nativeFormField()
                    .padding(.top, 2)
                    HStack {
                        NativeFormHint(text: "\(members.members.count) in this group.")
                        Spacer(minLength: 8)
                        // Any member may ask a friend of their own in, as any
                        // member may hand out the group's link.
                        Button("Invite friends…") { navigate(.addMembers(members.group.id)) }
                            .nativeSettingsActionButton()
                    }
                }
                NativeFormRow("", alignment: .center) {
                    Button(role: .destructive) {
                        confirm(
                            owner ? "Delete \(members.group.name)?" : "Leave \(members.group.name)?",
                            message: owner ? "This deletes the group for everyone. This cannot be undone." :
                                "You will no longer have access to this group's leaderboard.",
                            button: owner ? "Delete group" : "Leave group"
                        ) { model.remove { navigate(.list) } }
                    } label: {
                        NativeAsyncButtonLabel(
                            title: owner ? "Delete group…" : "Leave group…",
                            loadingTitle: owner ? "Deleting…" : "Leaving…",
                            isLoading: model.operation == "remove"
                        )
                    }
                    .nativeSettingsActionButton()
                }
                .padding(.top, 6)
            } footer: {
                if owner {
                    NativeFormFooter(error: footerError) {
                        Button("Cancel") { navigate(.list) }
                            .nativeFormCancelButton()
                            .keyboardShortcut(.cancelAction)
                        Spacer(minLength: 12)
                        submitButton("Save", loading: "Saving…", key: "save") {
                            model.save { navigate(.list) }
                        }
                        .disabled(!model.validName || !model.hasChanges)
                    }
                } else if let error = footerError {
                    NativeFormFooter(error: error) { EmptyView() }
                }
            }
        }
    }

    private var nameField: some View {
        NativeFormTextField(placeholder: "Group name", text: $model.name, title: "Group name")
    }

    private func addMembersForm(_ id: String) -> some View {
        NativeFormScreen {
            NativeFormRow("Friends") {
                if model.eligibleMembers.isEmpty {
                    Text("No friends left to invite. You can invite someone with a link from the group settings.")
                        .foregroundStyle(.secondary).padding(.vertical, 4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.eligibleMembers.enumerated()), id: \.element.id) { index, person in
                            Toggle(isOn: Binding(
                                get: { model.selectedMembers.contains(person.id) },
                                set: { selected in
                                    if selected { model.selectedMembers.insert(person.id) }
                                    else { model.selectedMembers.remove(person.id) }
                                }
                            )) {
                                HStack(spacing: 10) {
                                    FirstlightAvatar(url: person.avatar_url, name: person.displayName, size: 26)
                                    Text(person.displayName).lineLimit(1)
                                    if person.invitation_id != nil {
                                        Spacer(minLength: 8)
                                        Text("Invited").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(person.invitation_id != nil)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            if index < model.eligibleMembers.count - 1 { Divider().padding(.leading, 10) }
                        }
                    }
                    .padding(.vertical, 2)
                    .nativeFormField()
                    .padding(.top, 2)
                    NativeFormHint(text: "They join once they accept.")
                }
            }
        } footer: {
            NativeFormFooter(error: footerError) {
                Button("Cancel") { navigate(.details(id)) }
                    .nativeFormCancelButton()
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 12)
                submitButton("Invite", loading: "Inviting…", key: "add-members") {
                    model.addMembers { navigate(.details($0)) }
                }.disabled(model.selectedMembers.isEmpty)
            }
        }
    }

    private func submitButton(
        _ title: String,
        loading: String,
        key: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            NativeFormSubmitLabel(title: title, loadingTitle: loading, isLoading: model.operation == key)
        }
        .nativeFormSubmitButton()
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func confirm(_ title: String, message: String, button: String, action: @escaping () -> Void) {
        self.confirmationTitle = title
        self.confirmationMessage = message
        self.confirmationButton = button
        self.confirmationAction = action
        self.confirming = true
    }
}
