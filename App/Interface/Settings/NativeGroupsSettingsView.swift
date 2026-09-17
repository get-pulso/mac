import SwiftUI

struct NativeGroupsSettingsView: View {
    // MARK: Internal

    @ObservedObject var model: NativeGroupsModel
    let navigate: (NativeGroupsPage) -> Void

    var body: some View {
        Group {
            if !model.loaded, model.loading {
                loadingPlaceholder
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

    /// What the list already knows about the group being opened. Its owner
    /// edits the name in a field and saves it from a footer and nobody else
    /// does, so the skeleton can wait in the right one's shape. Not knowing
    /// counts as a member: the screen then gains a footer rather than losing
    /// one.
    private var opensAsOwner: Bool {
        guard let id = self.model.page.groupID else { return false }
        return self.model.groups.first { $0.id == id }?.is_creator == true
    }

    /// Every page used to wait as the labelled rows a list loads with, so
    /// opening a group drew a list's shape and then replaced it with a form.
    /// Each waits in its own now.
    @ViewBuilder private var loadingPlaceholder: some View {
        switch model.page {
        case .details: NativeGroupDetailsSkeleton(owner: opensAsOwner)
        case .addMembers: NativeInviteFriendsSkeleton()
        case .list,
             .create: Form { Section { NativeLabeledRowsSkeleton(rows: 4) } }
        }
    }

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

/// Sizes the group screens' skeletons take from the screens themselves.
private enum NativeGroupsSkeletonMetrics {
    // MARK: Internal

    /// Where the first name in a people panel sits, measured from the top of
    /// its row: the panel's own inset, the field chrome, a row's padding, and
    /// the gap that centres a line of text on a 26pt avatar. The label in the
    /// column beside it lines up with that name.
    static let panelFirstLine: CGFloat = 2 + NativeFormMetrics.fieldVerticalPadding + 2 + 6 + 5
    /// A bordered action button in the settings font: the copy button, the
    /// one that invites, and the one that removes somebody, all the same.
    static let button: CGFloat = 24
    /// The capsule a footer's buttons wear at their larger control size.
    static let footerButton: CGFloat = 30

    /// Names are not all one length, so a panel's rows do not read as a stack
    /// of identical bars while they wait.
    static func nameWidth(_ index: Int) -> CGFloat { self.nameWidths[index % self.nameWidths.count] }

    // MARK: Private

    private static let nameWidths: [CGFloat] = [78, 58, 94, 66]
}

/// One row of a form screen while it loads: a bar in the label column, the
/// field's placeholders beside it. `NativeFormRow` lines its label up with the
/// first line of text in the field, and a row of bars has no text to be found
/// by, so each one says instead how far down its own first line starts.
private struct NativeFormRowSkeleton<Content: View>: View {
    var labelWidth: CGFloat = 0
    var alignment: VerticalAlignment = .top
    var firstLine: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: alignment, spacing: NativeFormMetrics.columnSpacing) {
            // A row without a label still holds its column open, so a zero
            // width rather than nothing at all: an empty view in a fixed frame
            // drops out of the stack, taking the column and its spacing with it.
            NativeSkeletonTextLine(width: labelWidth)
                .frame(width: NativeFormMetrics.labelWidth, alignment: .trailing)
                .padding(.top, firstLine)
            VStack(alignment: .leading, spacing: 6, content: content)
                .frame(maxWidth: NativeFormMetrics.fieldMaxWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bordered panel both group screens list people in, before anyone is in
/// it: 26pt avatars on the rows' own inset, dividers where the loaded rows put
/// them, so the panel comes back at the height it stood at.
private struct NativePeoplePanelSkeleton<Trailing: View>: View {
    var rows: Int
    /// The invite screen leads every row with a checkbox, and runs its
    /// dividers past the avatars because of it.
    var checkbox = false
    @ViewBuilder var trailing: (Int) -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< rows, id: \.self) { index in
                HStack(spacing: 5) {
                    if checkbox { NativeSkeletonShape(width: 16, height: 16, radius: 4) }
                    HStack(spacing: 10) {
                        NativeSkeletonShape(width: 26, height: 26, radius: 13)
                        NativeSkeletonTextLine(width: NativeGroupsSkeletonMetrics.nameWidth(index))
                        Spacer(minLength: 8)
                        trailing(index)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                if index < rows - 1 { Divider().padding(.leading, checkbox ? 10 : 46) }
            }
        }
        .padding(.vertical, 2)
        .nativeFormField()
        .padding(.top, 2)
    }
}

/// The Cancel and submit buttons a form screen keeps under it, as the capsules
/// they come back as. The body's skeleton stops at the scroll view, so the
/// footer carries its own.
private struct NativeFormFooterSkeleton: View {
    var submitWidth: CGFloat

    var body: some View {
        NativeFormFooter {
            NativeDelayedSkeleton {
                HStack(spacing: 10) {
                    NativeSkeletonShape(width: 68, height: NativeGroupsSkeletonMetrics.footerButton, radius: 15)
                    Spacer(minLength: 12)
                    NativeSkeletonShape(
                        width: submitWidth,
                        height: NativeGroupsSkeletonMetrics.footerButton,
                        radius: 15
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// A group's own screen while its roster loads: the name, the invite button,
/// the panel the members arrive in, and the button under them, each where the
/// loaded screen puts it.
private struct NativeGroupDetailsSkeleton: View {
    // MARK: Internal

    /// The two screens are not the same height: the owner edits the name in a
    /// field and saves it from a footer, everyone else reads it and leaves.
    var owner: Bool
    /// Three rows: the panel is what sets this screen's height, and a group
    /// somebody opens is usually a handful of people.
    var rows = 3

    var body: some View {
        NativeFormScreen {
            NativeDelayedSkeleton {
                VStack(alignment: .leading, spacing: NativeFormMetrics.rowSpacing) {
                    NativeFormRowSkeleton(
                        labelWidth: 36,
                        firstLine: owner ? NativeFormMetrics.fieldVerticalPadding : 4
                    ) { name }
                    NativeFormRowSkeleton(labelWidth: 56, alignment: .center) {
                        NativeSkeletonShape(width: 116, height: NativeGroupsSkeletonMetrics.button, radius: 6)
                        NativeSkeletonTextLine(width: 198).font(.caption)
                    }
                    NativeFormRowSkeleton(
                        labelWidth: 56,
                        firstLine: NativeGroupsSkeletonMetrics.panelFirstLine
                    ) { roster }
                    NativeFormRowSkeleton(alignment: .center) {
                        NativeSkeletonShape(
                            width: owner ? 113 : 109,
                            height: NativeGroupsSkeletonMetrics.button,
                            radius: 6
                        )
                    }
                    .padding(.top, 6)
                }
            }
        } footer: {
            // Only the owner has anything to save.
            if owner { NativeFormFooterSkeleton(submitWidth: 57) }
        }
    }

    // MARK: Private

    @ViewBuilder private var name: some View {
        if owner {
            NativeSkeletonTextLine(width: 92)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nativeFormField()
        } else {
            NativeSkeletonTextLine(width: 92).padding(.vertical, 4)
        }
    }

    @ViewBuilder private var roster: some View {
        NativePeoplePanelSkeleton(rows: rows) { index in
            // The group's creator is its first member and the one row that
            // always carries something on the right; its owner also gets a
            // button to take anybody else out.
            if index == 0 {
                NativeSkeletonTextLine(width: 32).font(.caption)
            } else if owner {
                NativeSkeletonShape(width: 83, height: NativeGroupsSkeletonMetrics.button, radius: 6)
            }
        }
        HStack {
            NativeSkeletonTextLine(width: 72).font(.caption)
            Spacer(minLength: 8)
            NativeSkeletonShape(width: 113, height: NativeGroupsSkeletonMetrics.button, radius: 6)
        }
    }
}

/// The invite screen while it asks who is left to invite: the same panel, led
/// by the checkboxes that pick people out of it.
private struct NativeInviteFriendsSkeleton: View {
    /// Four rows: a friend list, not a group's roster, and it opens longer
    /// than the group it invites into.
    var rows = 4

    var body: some View {
        NativeFormScreen {
            NativeDelayedSkeleton {
                NativeFormRowSkeleton(
                    labelWidth: 44,
                    firstLine: NativeGroupsSkeletonMetrics.panelFirstLine
                ) {
                    NativePeoplePanelSkeleton(rows: rows, checkbox: true) { _ in EmptyView() }
                    NativeSkeletonTextLine(width: 132).font(.caption)
                }
            }
        } footer: {
            NativeFormFooterSkeleton(submitWidth: 59)
        }
    }
}
