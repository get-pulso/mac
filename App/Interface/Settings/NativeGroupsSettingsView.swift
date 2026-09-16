import SwiftUI

struct NativeGroupsSettingsView: View {
    // MARK: Internal

    @ObservedObject var model: NativeGroupsModel
    let navigate: (NativeGroupsPage) -> Void

    var body: some View {
        Form {
            if !model.loaded, model.loading {
                Section { NativeLabeledRowsSkeleton(rows: 4) }
            } else if !model.loaded, let error = model.loadError {
                NativeStateMessage(
                    title: "Couldn't load groups",
                    message: error,
                    actionTitle: "Retry",
                    action: model.reload
                )
            } else {
                pageContent
            }
            if let error = model.error { NativeInlineError(message: error) }
            if model.loaded, let error = model.loadError { NativeInlineError(message: error, retry: model.reload) }
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

    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .list: groupList
        case .create: createForm
        case .details: groupDetails
        case let .addMembers(id): addMembersForm(id)
        }
    }

    private var groupList: some View {
        Group {
            Section("Your groups") {
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
        }
    }

    private var createForm: some View {
        Group {
            Section {
                nameField
            } header: { Text("Group details") } footer: {
                Text("Only members can see activity in this group.")
            }
            HStack {
                Spacer()
                Button("Cancel") { navigate(.list) }
                    .nativeSettingsActionButton()
                actionButton("Create group", loading: "Creating…", key: "create", primary: true) {
                    model.create { navigate(.details($0)) }
                }.disabled(!model.validName)
            }
        }
    }

    @ViewBuilder private var groupDetails: some View {
        if let members = model.members {
            Section("Group details") {
                if members.group.is_user_creator {
                    nameField
                    HStack {
                        Spacer()
                        actionButton("Save changes", loading: "Saving…", key: "save", primary: true, action: model.save)
                            .disabled(!model.validName || !model.hasChanges)
                    }
                } else {
                    LabeledContent("Group name", value: members.group.name)
                }
            }
            Section("Invitation") {
                Picker("Link can be used", selection: $model.usageLimit) {
                    Text("Once").tag(1)
                    Text("5 times").tag(5)
                    Text("10 times").tag(10)
                    Text("25 times").tag(25)
                }
                LabeledContent("Invite people to this group") {
                    Button(action: model.copyInvite) {
                        NativeCopyButtonLabel(
                            title: "Copy invite link",
                            copied: model.copied,
                            loadingTitle: "Creating…",
                            isLoading: model.operation == "invite"
                        )
                    }
                    .nativeSettingsActionButton()
                }
            }
            Section {
                ForEach(members.members) { person in
                    HStack(spacing: 10) {
                        PulsoAvatar(url: person.avatar_url, name: person.displayName, size: 28)
                        Text(person.displayName).lineLimit(2)
                        Spacer(minLength: 8)
                        if person.is_creator == true {
                            Text("Owner").foregroundStyle(.secondary)
                        } else if members.group.is_user_creator {
                            actionButton("Remove…", loading: "Removing…", key: "remove-\(person.id)") {
                                confirm(
                                    "Remove \(person.displayName)?",
                                    message: "They will no longer have access to this group.",
                                    button: "Remove"
                                ) {
                                    model.removeMember(person)
                                }
                            }
                        }
                    }.padding(.vertical, 2)
                }
                if members.group.is_user_creator {
                    HStack {
                        Spacer()
                        Button("Add friends…") { navigate(.addMembers(members.group.id)) }
                            .nativeSettingsActionButton()
                    }
                }
            } header: { Text("Members (\(members.members.count))") }
            Button(role: .destructive) {
                let owner = members.group.is_user_creator
                confirm(
                    owner ? "Delete \(members.group.name)?" : "Leave \(members.group.name)?",
                    message: owner ? "This deletes the group for everyone. This cannot be undone." :
                        "You will no longer have access to this group's leaderboard.",
                    button: owner ? "Delete group" : "Leave group"
                ) { model.remove { navigate(.list) } }
            } label: {
                NativeAsyncButtonLabel(
                    title: members.group.is_user_creator ? "Delete group…" : "Leave group…",
                    loadingTitle: members.group.is_user_creator ? "Deleting…" : "Leaving…",
                    isLoading: model.operation == "remove"
                )
            }
            .nativeSettingsActionButton()
        }
    }

    private var nameField: some View {
        LabeledContent("Group name") {
            TextField("Group name", text: $model.name).labelsHidden()
                .frame(minWidth: 140, maxWidth: 270)
        }
    }

    private func addMembersForm(_ id: String) -> some View {
        Group {
            Section {
                if model.eligibleMembers.isEmpty {
                    Text("No friends available to add. You can invite someone with a link from the group settings.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.eligibleMembers) { person in
                        Toggle(isOn: Binding(
                            get: { model.selectedMembers.contains(person.id) },
                            set: { selected in
                                if selected { model.selectedMembers.insert(person.id) }
                                else { model.selectedMembers.remove(person.id) }
                            }
                        )) {
                            HStack(spacing: 10) {
                                PulsoAvatar(url: person.avatar_url, name: person.displayName, size: 28)
                                Text(person.displayName).lineLimit(2)
                            }
                        }.toggleStyle(.checkbox).padding(.vertical, 2)
                    }
                }
            } header: { Text("Your friends") } footer: { Text("Select friends to add to this group.") }
            HStack {
                Spacer()
                Button("Cancel") { navigate(.details(id)) }
                    .nativeSettingsActionButton()
                actionButton("Add friends", loading: "Adding…", key: "add-members", primary: true) {
                    model.addMembers { navigate(.details($0)) }
                }.disabled(model.selectedMembers.isEmpty)
            }
        }
    }

    @ViewBuilder private func actionButton(
        _ title: String,
        loading: String,
        key: String,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            NativeAsyncButtonLabel(title: title, loadingTitle: loading, isLoading: model.operation == key)
        }
        if primary { button.nativeSettingsPrimaryButton().keyboardShortcut(.defaultAction) }
        else { button.nativeSettingsActionButton() }
    }

    private func confirm(_ title: String, message: String, button: String, action: @escaping () -> Void) {
        self.confirmationTitle = title
        self.confirmationMessage = message
        self.confirmationButton = button
        self.confirmationAction = action
        self.confirming = true
    }
}
