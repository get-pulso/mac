import Defaults
import Dependencies
import NukeUI
import SwiftUI

/// Distance from the top of the scrolling viewport to the bottom of a detail
/// screen's own title. Negative once the title has scrolled past the header.
private struct ProfileTitleBottom: PreferenceKey {
    static var defaultValue: CGFloat { .greatestFiniteMagnitude }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

struct NativeDashboardView: View {
    // MARK: Internal

    var body: some View {
        Group {
            if store.screen == .list {
                people
            } else {
                VStack(spacing: 0) {
                    if isPersonScreen { profileHeader }
                    else { subheader }
                    if !isPersonScreen { Divider().opacity(0.5) }
                    PopoverContent(reservesMaximumHeight: self.isLoadingProfileActivity) {
                        if needsInitialLoad { detailSkeleton }
                        else if store.screen != .connect, store.error != nil, !store.hasLoaded(store.screen) {
                            NativeStateMessage(
                                title: "Couldn't load \(screenTitle.lowercased())",
                                message: "Check your connection and try again.",
                                actionTitle: "Retry",
                                action: store.retry
                            )
                        } else {
                            content.disabled(store.busy)
                            if let error = store.error { NativeInlineError(message: error, retry: store.retry) }
                        }
                    }
                }
                .onPreferenceChange(ProfileTitleBottom.self) { bottom in profileTitleBottom = bottom }
                .onChange(of: store.screen) { _, _ in profileTitleBottom = .greatestFiniteMagnitude }
            }
        }
        .textFieldStyle(.roundedBorder).controlSize(.regular).font(.system(size: 13))
        .overlay(alignment: .top) {
            if let feedback = store.feedbackToast {
                NativeFeedbackToast(state: feedback)
                    .padding(.top, NativeLayout.popoverHeaderHeight + 7)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                    .zIndex(1)
            } else if let notice = store.notice {
                NativeFeedbackToast(state: .success(notice))
                    .padding(.top, NativeLayout.popoverHeaderHeight + 7)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.16), value: store.feedbackToast)
        .animation(.snappy(duration: 0.16), value: store.notice)
        .task { resumeInvite() }
        .task(id: store.tab + store.period) { await store.refresh() }
        .task(id: store.feedbackToast) {
            guard case let .success(message) = store.feedbackToast else { return }
            let expected = SocialStore.FeedbackToast.success(message)
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            guard store.feedbackToast == expected else { return }
            withAnimation(.easeOut(duration: 0.14)) { store.feedbackToast = nil }
        }
        .task(id: store.notice) {
            guard let notice = store.notice else { return }
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            guard store.notice == notice else { return }
            withAnimation(.easeOut(duration: 0.14)) { store.notice = nil }
        }
        .onReceive(timer) { _ in refreshVisibleScreen() }
        .onReceive(windowManager.isVisiblePublisher.removeDuplicates().dropFirst()) { visible in
            if visible { refreshVisibleScreen() }
        }
        .onExitCommand { if store.screen == .list { windowManager.hide() } else { store.goBack() } }
        .onChange(of: session.pendingInvite) { _, _ in resumeInvite() }
        .alert(confirmationTitle, isPresented: $confirming) {
            Button("Cancel", role: .cancel) { confirmationAction = nil }
            Button("Confirm", role: .destructive) { confirmationAction?(); confirmationAction = nil }
        }
    }

    // MARK: Private

    /// Every row column shares the avatar's vertical centre, so the name, the
    /// duration and the running app sit on one line whether or not the profile
    /// carries a second line. The divider starts exactly where the text does.
    private static let rowHorizontalPadding: CGFloat = 12
    private static let rowAvatarSize: CGFloat = 40
    private static let rowAvatarSpacing: CGFloat = 10
    private static let rowDividerInset = rowHorizontalPadding + rowAvatarSize + rowAvatarSpacing

    @ObservedObject private var store = SocialStore.shared
    @ObservedObject private var session = NativeSession.shared
    @Dependency(\.windowManager) private var windowManager
    @State private var confirming = false
    @State private var confirmationTitle = ""
    @State private var confirmationAction: (() -> Void)?
    @State private var headerScrollFades = HorizontalScrollFades()
    @State private var profileTitleBottom = CGFloat.greatestFiniteMagnitude
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// The header stays empty until the profile's own name has scrolled out of
    /// the viewport, then takes the name over.
    private var showsProfileHeaderTitle: Bool { self.profileTitleBottom < 2 }

    /// The leaderboard already tells us whether this profile has activity.
    /// Reserve the finished profile height while its app breakdown catches up,
    /// instead of shrinking the popover and expanding it again a moment later.
    private var isLoadingProfileActivity: Bool {
        guard case .person = self.store.screen,
              self.store.screenLoading,
              self.store.activity == nil,
              let minutes = self.store.selectedPerson?.active_minutes
        else { return false }
        return minutes > 0
    }

    private var needsInitialLoad: Bool {
        // The add-friends screen is usable while its invitation data loads.
        if self.store.screen == .connect { return false }
        return self.store.screenLoading && !self.store.hasLoaded(self.store.screen)
    }

    private var isPersonScreen: Bool {
        if case .person = self.store.screen { return true }
        return false
    }

    private var header: some View {
        HStack(spacing: 7) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        tab("Friends", id: "friends")
                        ForEach(store.groups) { group in
                            tab(group.name, id: group.id)
                                .contextMenu {
                                    Button {
                                        SettingsWindowController.shared.show(
                                            section: .groups,
                                            groupsPage: .details(group.id)
                                        )
                                    } label: {
                                        Label("Group settings", systemImage: "gearshape")
                                    }
                                    Button {
                                        store.copyGroupInvite(group.id)
                                    } label: {
                                        Label("Copy invite link", systemImage: "doc.on.doc")
                                    }
                                    .disabled(store.busy)
                                }
                        }
                        tab("Leaderboard", id: "global")
                    }
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: HorizontalScrollFades.self) { geometry in
                    HorizontalScrollFades(geometry: geometry)
                } action: { _, fades in
                    self.headerScrollFades = fades
                }
                .mask { HorizontalScrollFadeMask(fades: self.headerScrollFades) }
                .onChange(of: store.tab) { _, value in withAnimation { reader.scrollTo(value, anchor: .center) } }
            }
            .frame(maxWidth: .infinity)

            periodPicker
        }
        .padding(.horizontal, Self.rowHorizontalPadding)
        .frame(height: NativeLayout.popoverHeaderHeight)
    }

    private var periodPicker: some View {
        Menu {
            periodMenuButton("Day", value: "24h")
            periodMenuButton("Week", value: "7d")
            periodMenuButton("Month", value: "30d")
        } label: {
            HStack(spacing: 4) {
                Text(periodLabel)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .animation(.snappy(duration: 0.22, extraBounce: 0), value: self.store.period)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Choose activity period")
        .accessibilityLabel("Activity period")
        .accessibilityValue(periodLabel)
    }

    private var periodLabel: String {
        switch self.store.period {
        case "7d": "Week"
        case "30d": "Month"
        default: "Day"
        }
    }

    private var subheader: some View {
        HStack(spacing: 10) {
            NativeBackButton(help: "Back to \(backDestinationTitle)") { store.goBack() }
            Text(screenTitle).font(.system(size: 13, weight: .medium))
            Spacer()
        }.padding(.horizontal, 12).frame(height: NativeLayout.popoverHeaderHeight)
    }

    private var profileHeader: some View {
        HStack(spacing: 0) {
            HStack {
                NativeBackButton(help: "Back to \(backDestinationTitle)") { store.goBack() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if self.showsProfileHeaderTitle {
                    Text(self.store.selectedPerson?.displayName ?? "Profile")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize()
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
            .animation(.snappy(duration: 0.2), value: self.showsProfileHeaderTitle)

            HStack {
                if case let .person(id) = store.screen {
                    if id == Defaults[.currentUserID] {
                        profileHeaderAction("Edit") {
                            SettingsWindowController.shared.show(section: .account, page: "edit")
                        }
                    } else if store.directFriendIDs.contains(id), let person = store.selectedPerson {
                        profileHeaderAction(
                            "Remove",
                            isLoading: store.isRunning("remove-friend-\(id)")
                        ) {
                            removeFriend(person, id: id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: NativeLayout.popoverHeaderHeight)
    }

    @ViewBuilder private var people: some View {
        if #available(macOS 26.0, *) {
            peopleList
                .safeAreaBar(edge: .top, spacing: 0) { header }
                .safeAreaBar(edge: .bottom, spacing: 0) { peopleFooter }
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .frame(height: NativeLayout.popoverHeaderHeight + NativeLayout.peopleBodyHeight)
        } else {
            peopleList
                .safeAreaInset(edge: .top, spacing: 0) {
                    legacyPeopleBar(edge: .top) { header }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    legacyPeopleBar(edge: .bottom) { peopleFooter }
                }
                .frame(height: NativeLayout.popoverHeaderHeight + NativeLayout.peopleBodyHeight)
        }
    }

    private var peopleFooter: some View {
        HStack(spacing: 8) {
            dashboardSettingsButton
            Spacer()
            dashboardInviteButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 12)
        .frame(height: NativeLayout.peopleFooterHeight)
    }

    @ViewBuilder private var dashboardSettingsButton: some View {
        if #available(macOS 26.0, *) {
            Button { SettingsWindowController.shared.show() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)
        } else {
            Button { SettingsWindowController.shared.show() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    @ViewBuilder private var dashboardInviteButton: some View {
        let label = Text("Invite").font(.system(size: 12, weight: .medium))

        if #available(macOS 26.0, *) {
            Button { store.open(.connect) } label: { label }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .tint(.accentColor)
                .help("Add a friend")
        } else {
            Button { store.open(.connect) } label: { label }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .tint(.accentColor)
                .help("Add a friend")
        }
    }

    private var peopleList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch listPhase {
                case .initial:
                    NativePeopleSkeleton(rows: 5)
                case .failedEmpty:
                    NativeStateMessage(
                        title: "Couldn't load activity",
                        message: "Check your connection and try again.",
                        actionTitle: "Retry",
                        action: { Task { await store.refresh(force: true) } }
                    )
                case .empty:
                    NativeStateMessage(
                        title: "No activity yet",
                        message: store.tab == "global" ? "No activity for this period." :
                            "Invite a friend or join a group to get started.",
                        actionTitle: store.tab == "global" ? nil : "Invite a friend",
                        action: store.tab == "global" ? nil : { store.open(.connect) }
                    )
                case .content,
                     .refreshing,
                     .failedWithContent:
                    ForEach(Array(store.people.enumerated()), id: \.element.id) { index, person in
                        Button {
                            store.selectedPerson = person
                            store.open(.person(person.id))
                        } label: { personRow(person) }.buttonStyle(.plain)
                        if index < store.people.count - 1 {
                            Divider().padding(.leading, Self.rowDividerInset).opacity(0.55)
                        }
                    }
                    if listPhase == .failedWithContent {
                        NativeInlineError(message: store.listError ?? "Couldn't refresh activity") {
                            Task { await store.refresh(force: true) }
                        }.padding(12)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Everything the screen is for, in the order it gets used: who is waiting
    /// on you, a field for someone else's invitation, then your own.
    private var connectScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !self.store.requests.incoming.isEmpty {
                self.sectionHeading("Wants to be friends")
                ForEach(self.store.requests.incoming) { request in
                    if let person = request.requester {
                        self.requestRow(person, detail: "Sent you a friend request") {
                            self.operationButton(
                                "Accept",
                                loadingTitle: "Accepting…",
                                key: "accept-request-\(request.id)",
                                prominent: true
                            ) { self.store.respond(request.id, action: "accept") }
                            self.operationButton(
                                "Decline",
                                loadingTitle: "Declining…",
                                key: "decline-request-\(request.id)"
                            ) { self.store.respond(request.id, action: "decline") }
                        }
                    }
                }
                Divider()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Their invitation").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Paste a link or enter a friend code", text: self.$store.query)
                    .labelsHidden()
                    .onChange(of: self.store.query) { _, _ in self.store.queryChanged() }
                    .onSubmit { self.store.addFromQuery() }
            }
            self.inviteBanner
            Divider()
            self.yourInviteBlock
            if !self.store.requests.outgoing.isEmpty {
                Divider()
                self.navigationRow(
                    "Sent requests",
                    detail: self.store.requests.outgoing.count == 1 ? "1 waiting for a reply" :
                        "\(self.store.requests.outgoing.count) waiting for a reply"
                ) { self.store.open(.requests) }
            }
        }
    }

    @ViewBuilder private var yourInviteBlock: some View {
        if let invite = store.personalInvite {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR FRIEND CODE").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(self.displayFriendCode(invite.personalInviteCode))
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .tracking(1.5).lineLimit(1).minimumScaleFactor(0.68).textSelection(.enabled)
                    .accessibilityLabel("Your friend code \(invite.personalInviteCode)")
                HStack(spacing: 6) {
                    Button { self.store.copyFriendCode(invite.personalInviteCode) } label: {
                        NativeCopyButtonLabel(title: "Copy code", copied: self.store.copiedItem == .friendCode)
                    }.controlSize(.small).disabled(self.store.busy)
                    Button { self.store.copyPersonalInviteLink() } label: {
                        NativeCopyButtonLabel(
                            title: "Copy link",
                            copied: self.store.copiedItem == .inviteLink,
                            loadingTitle: "Preparing…",
                            isLoading: self.store.isRunning("copy-invite-link")
                        )
                    }.controlSize(.small).disabled(self.store.busy)
                    Spacer(minLength: 0)
                }
                Text("Show the code nearby, or send the same invitation as a link.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if store.screenLoading {
            NativeDelayedSkeleton {
                VStack(alignment: .leading, spacing: 10) {
                    NativeSkeletonShape(width: 108, height: 13)
                    NativeSkeletonShape(width: 154, height: 28, radius: 5)
                    NativeSkeletonShape(width: 168, height: 20, radius: 6)
                }.padding(12)
            }
        } else {
            self.quiet("Your friend code isn't available right now.")
        }
    }

    /// A pasted link or code answers itself in place: the list shows who is
    /// inviting and the single action that follows from it.
    @ViewBuilder private var inviteBanner: some View {
        if let candidate = store.inviteCandidate {
            let prompt = self.invitePrompt(for: candidate)
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: prompt.icon)
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(prompt.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(prompt.message).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    if self.store.checkingInvite {
                        NativeProgress(active: true, label: "Checking invitation")
                    }
                }
                HStack(spacing: 6) {
                    if let actionTitle = prompt.actionTitle {
                        Button { self.store.addFromQuery() } label: {
                            NativeAsyncButtonLabel(
                                title: actionTitle,
                                loadingTitle: prompt.loadingTitle,
                                isLoading: self.store.isRunning("accept-invite")
                            )
                        }.buttonStyle(.borderedProminent).controlSize(.small).disabled(self.store.busy)
                    } else if self.store.inviteError != nil {
                        Button("Try again") { self.store.queryChanged() }
                            .controlSize(.small).disabled(self.store.busy)
                    }
                    Button("Dismiss") { self.store.dismissInvite() }
                        .controlSize(.small).disabled(self.store.busy)
                    Spacer(minLength: 0)
                }
                if prompt.actionTitle != nil {
                    HStack(spacing: 5) {
                        Text("As \(self.accountLabel)").font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Switch…") { self.switchAccountForInvite() }
                            .buttonStyle(.link).font(.system(size: 11)).disabled(self.store.busy)
                    }
                }
            }
            .padding(11)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var accountLabel: String {
        self.session.user?.primaryEmailAddress?.emailAddress ?? "your current account"
    }

    private var listPhase: ContentLoadPhase {
        ContentLoadPhase.resolve(
            isLoading: self.store.loading && !self.store.hasLoadedCurrentList,
            hasContent: !self.store.people.isEmpty,
            hasError: self.store.listError != nil
        )
    }

    @ViewBuilder private var detailSkeleton: some View {
        switch store.screen {
        case .requests:
            NativeRowsSkeleton(rows: 3, showActions: true)
        default:
            NativeMetricSkeleton()
        }
    }

    @ViewBuilder private var content: some View {
        switch store.screen {
        case .list: EmptyView()
        case .connect: connectScreen
        case .requests:
            intro("Sent requests", message: "Invitations you sent that are still waiting.")
            if store.requests.outgoing.isEmpty { quiet("No pending requests.") }
            ForEach(store.requests.outgoing) { request in
                if let person = request.target_user {
                    requestRow(person, detail: "Waiting for a response") {
                        operationButton(
                            "Cancel",
                            loadingTitle: "Cancelling…",
                            key: "cancel-request-\(request.id)"
                        ) { store.respond(request.id, action: "cancel") }
                    }
                }
            }
        case let .person(id): personDetail(id)
        }
    }

    private var screenTitle: String {
        self.screenTitle(for: self.store.screen)
    }

    private var backDestinationTitle: String {
        self.screenTitle(for: self.store.previousScreen ?? .list)
    }

    private func periodMenuButton(_ label: String, value: String) -> some View {
        Button { self.store.setPeriod(value) } label: {
            if self.store.period == value {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    @ViewBuilder private func profileHeaderAction(
        _ title: String,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let label = ZStack {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary)
            }
        }
        .frame(minWidth: 42, minHeight: 22)

        if #available(macOS 26.0, *) {
            Button(action: action) { label }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(store.busy)
                .help(title)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(self.store.busy)
                .help(title)
        }
    }

    private func removeFriend(_ person: NativePerson, id: String) {
        self.confirm("Remove \(person.displayName) from your friends?") {
            store.run("Removing friend…", key: "remove-friend-\(id)") {
                try await store.mutate("/api/friends/\(id)/delete", method: .delete)
                store.removeDirectFriend(id)
                store.showList(notice: "Friend removed.")
                await store.refresh(force: true)
            }
        }
    }

    private func screenTitle(for screen: SocialStore.Screen) -> String {
        switch screen {
        case .list: "Friends"
        case .connect: "Add friends"
        case .requests: "Sent requests"
        case .person: "Profile"
        }
    }

    private func displayFriendCode(_ code: String) -> String {
        guard !code.contains("-"), code.count >= 6, code.count <= 12 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<middle]) \(code[middle...])"
    }

    private func legacyPeopleBar(
        edge: VerticalEdge,
        @ViewBuilder content: () -> some View
    ) -> some View {
        content()
            .background(.ultraThinMaterial)
            .background(alignment: edge == .top ? .bottom : .top) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        LinearGradient(
                            colors: edge == .top ? [.black, .clear] : [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 22)
                    .offset(y: edge == .top ? 22 : -22)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private func tab(_ label: String, id: String) -> some View {
        Button { store.tab = id } label: {
            Text(label).font(.system(size: 13, weight: .medium)).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    store.tab == id ? Color.primary.opacity(0.11) : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }.buttonStyle(.plain).id(id).accessibilityAddTraits(self.store.tab == id ? [.isSelected] : [])
    }

    private func personRow(_ person: NativePerson) -> some View {
        let location = self.profileText(person.location)
        let subtitle = [location, profileText(person.bio)].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: Self.rowAvatarSpacing) {
            PulsoAvatar(
                url: person.avatar_url,
                name: person.displayName,
                size: Self.rowAvatarSize,
                showsOnlineIndicator: person.id == Defaults[.currentUserID] || person.isActiveNow
            )
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(person.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if person
                            .id ==
                            Defaults[.currentUserID] { Text("You").foregroundStyle(.tertiary).font(.system(size: 13)) }
                    }
                    if !subtitle.isEmpty {
                        HStack(spacing: 3) {
                            if location != nil { NativeLocationIcon().foregroundStyle(.secondary) }
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    AnimatedDuration(minutes: person.active_minutes ?? 0)
                        .foregroundStyle(.secondary).font(.system(size: 12))
                        .fixedSize()
                    if let activeApp = person.active_app, person.isActiveNow {
                        HStack(spacing: 4) {
                            NativeTrackedAppIcon(url: activeApp.icon_url, size: 16)
                            Text(activeApp.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: 110, alignment: .trailing)
                        .help(activeApp.name)
                    }
                }
            }
            .frame(height: Self.rowAvatarSize)
        }
        .padding(.horizontal, Self.rowHorizontalPadding).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // Location and bio are the only profile text the list carries. Social links
    // stay on the person's profile. An unfilled profile gets no second line at
    // all, and the single title stays on the avatar's centre either way.
    private func profileText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func invitePrompt(for candidate: InviteInput) -> InvitePrompt {
        switch candidate {
        case let .friendCode(code):
            if code.caseInsensitiveCompare(self.store.personalInvite?.personalInviteCode ?? "") == .orderedSame {
                InvitePrompt(
                    icon: "person.crop.circle",
                    title: "That's your own friend code",
                    message: "Send it to someone else so they can add you.",
                    actionTitle: nil,
                    loadingTitle: ""
                )
            } else {
                InvitePrompt(
                    icon: "person.badge.plus",
                    title: "Send a friend request",
                    message: "Code \(self.displayFriendCode(code)). They choose whether to accept.",
                    actionTitle: "Send request",
                    loadingTitle: "Sending…"
                )
            }
        case .token:
            if let info = store.inviteInfo {
                InvitePrompt(
                    icon: "envelope.open",
                    title: info.invite.groupName,
                    message: "Invited by \(info.invite.inviterName) · \(self.memberCount(info.invite.memberCount))",
                    actionTitle: "Accept invitation",
                    loadingTitle: "Joining…"
                )
            } else if let error = store.inviteError {
                InvitePrompt(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't open this invitation",
                    message: error,
                    actionTitle: nil,
                    loadingTitle: ""
                )
            } else {
                InvitePrompt(
                    icon: "link",
                    title: "Checking this invitation…",
                    message: "Reading the link you pasted.",
                    actionTitle: nil,
                    loadingTitle: ""
                )
            }
        }
    }

    private func memberCount(_ count: Int) -> String {
        count == 1 ? "1 member" : "\(count) members"
    }

    private func switchAccountForInvite() {
        let invite = self.store.query
        self.confirm("Sign out and accept this invitation with another account?") {
            session.pendingInvite = invite
            store.run("Signing out…", key: "switch-account") { try await session.signOut() }
        }
    }

    @ViewBuilder private func personDetail(_ id: String) -> some View {
        if let person = store.selectedPerson {
            VStack(spacing: 8) {
                PulsoAvatar(
                    url: person.avatar_url,
                    name: person.displayName,
                    size: 76,
                    showsOnlineIndicator: id == Defaults[.currentUserID] || person.isActiveNow
                )

                Text(person.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(
                            key: ProfileTitleBottom.self,
                            value: geometry.frame(in: .named(NativeLayout.popoverScrollSpace)).maxY
                        )
                    })

                if let location = person.location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NativeLocationLabel(text: location)
                }
            }
            .frame(maxWidth: .infinity)

            if let bio = person.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(bio)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
            }

            if [person.website, person.twitter, person.telegram].contains(where: { $0?.isEmpty == false }) {
                HStack(spacing: 8) {
                    profileLink("Website", assetImage: "ProfileWebsite", raw: person.website)
                    profileLink(
                        "X",
                        assetImage: "ProfileX",
                        raw: person.twitter.map { $0.hasPrefix("https://") ? $0 : "https://x.com/\($0)" }
                    )
                    profileLink(
                        "Telegram",
                        assetImage: "ProfileTelegram",
                        raw: person.telegram.map { $0.hasPrefix("https://") ? $0 : "https://t.me/\($0)" }
                    )
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active time").font(.system(size: 13, weight: .medium))
                    Text(
                        store.period == "24h" ? "Last 24 hours" : store
                            .period == "7d" ? "Last 7 days" : "Last 30 days"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // The list already has the total. Keep it visible while a more
                // recent total loads; never replace known data with a spinner.
                if let minutes = store.activity?.active_minutes ?? person.active_minutes {
                    AnimatedDuration(minutes: minutes).font(.system(size: 20, weight: .medium))
                } else if store.screenLoading {
                    NativeSkeletonShape(width: 52, height: 20, radius: 5)
                } else {
                    Text("Unavailable").foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
            if self.isLoadingProfileActivity {
                NativeTrackedAppsSkeleton()
            }
            if let activeApp = store.activity?.active_app {
                self.trackedAppRow(activeApp, showsActiveState: true)
                    .padding(.horizontal, 4)
            }
            if let topApps = store.activity?.top_apps, !topApps.isEmpty {
                Divider()
                self.sectionHeading("Top apps")
                VStack(spacing: 0) {
                    ForEach(Array(topApps.prefix(5).enumerated()), id: \.element.id) { index, app in
                        trackedAppRow(app)
                        if index < min(topApps.count, 5) - 1 { Divider().padding(.leading, 38).opacity(0.5) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func profileLink(_ label: String, assetImage: String, raw: String?) -> some View {
        if let raw, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") {
            Link(destination: url) {
                VStack(spacing: 7) {
                    Image(assetImage)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.primary)
                    Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help(label)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Open \(label)")
        }
    }

    private func trackedAppRow(_ app: NativeAppActivity, showsActiveState: Bool = false) -> some View {
        HStack(spacing: 10) {
            NativeTrackedAppIcon(url: app.icon_url, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if showsActiveState {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Active now").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if !showsActiveState {
                AnimatedDuration(minutes: app.active_minutes)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func intro(_ title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .medium))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
    }

    private func navigationRow(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func requestRow(
        _ person: NativeContact,
        detail: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            PulsoAvatar(url: person.avatar_url, name: person.displayName, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) { actions() }.controlSize(.small)
        }.padding(.vertical, 3)
    }

    private func quiet(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func operationButton(
        _ title: String,
        loadingTitle: String,
        key: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if prominent {
                Button(action: action) {
                    NativeAsyncButtonLabel(
                        title: title,
                        loadingTitle: loadingTitle,
                        isLoading: store.isRunning(key)
                    )
                }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) {
                    NativeAsyncButtonLabel(
                        title: title,
                        loadingTitle: loadingTitle,
                        isLoading: store.isRunning(key)
                    )
                }
            }
        }.disabled(self.store.busy)
    }

    private func confirm(_ title: String, action: @escaping () -> Void) {
        self.confirmationTitle = title; self.confirmationAction = action; self.confirming = true
    }

    private func resumeInvite() {
        guard let value = session.pendingInvite else { return }
        self.store.open(.connect)
        self.store.query = value
        self.store.queryChanged()
    }

    private func refreshVisibleScreen() {
        guard self.windowManager.isVisible, !self.store.busy else { return }
        self.store.refreshCurrentScreen()
    }
}

private struct HorizontalScrollFades: Equatable {
    // MARK: Lifecycle

    init() {}

    init(geometry: ScrollGeometry) {
        let fadeDistance: CGFloat = 18
        let overflow = max(geometry.contentSize.width - geometry.containerSize.width, 0)
        let offset = min(max(geometry.contentOffset.x, 0), overflow)
        self.leading = min(offset / fadeDistance, 1)
        self.trailing = min((overflow - offset) / fadeDistance, 1)
    }

    // MARK: Internal

    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

private struct HorizontalScrollFadeMask: View {
    let fades: HorizontalScrollFades

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(1 - self.fades.leading), .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 18)

            Rectangle().fill(.black)

            LinearGradient(
                colors: [.black, .black.opacity(1 - self.fades.trailing)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 18)
        }
    }
}

private struct InvitePrompt {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let loadingTitle: String
}

private struct NativeFeedbackToast: View {
    let state: SocialStore.FeedbackToast

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if self.state.isLoading {
                    ProgressView().controlSize(.small).transition(.opacity)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.35).combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: self.state)

            Text(self.state.message).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .animation(.easeOut(duration: 0.12), value: self.state.message)
    }
}

struct PulsoAvatar: View {
    // MARK: Internal

    let url: String?
    let name: String
    var size: CGFloat = 44
    var showsOnlineIndicator = false

    var body: some View {
        LazyImage(url: url.flatMap(URL.init(string:))) { state in
            if let image = state.image { image.resizable().scaledToFill() }
            else {
                ZStack {
                    Color.primary.opacity(0.08); Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.35, weight: .medium))
                }
            }
        }
        .frame(width: size, height: size)
        .mask {
            PulsoAvatarMask(
                cutsOutOnlineIndicator: showsOnlineIndicator,
                indicatorSize: onlineIndicatorSize,
                indicatorInset: onlineIndicatorInset,
                indicatorGap: onlineIndicatorGap
            )
            .fill()
        }
        .overlay(alignment: .bottomTrailing) {
            if showsOnlineIndicator {
                Circle().fill(Color.green)
                    .frame(width: onlineIndicatorSize, height: onlineIndicatorSize)
                    .offset(x: -onlineIndicatorInset, y: -onlineIndicatorInset)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Private

    /// The indicator is a badge, not a part of the portrait: it needs a floor to stay
    /// readable on small avatars and a ceiling so it does not turn into an object of its
    /// own on large ones. Whole points keep the edge crisp on Retina.
    private var onlineIndicatorSize: CGFloat {
        min(16, max(8, (8 + (self.size - 24) * 6 / 52).rounded()))
    }

    private var onlineIndicatorGap: CGFloat { self.size <= 32 ? 1.5 : 2 }

    /// Holds the indicator centre on the diagonal at 0.315 x size from the avatar centre,
    /// whatever the diameter, so the badge stays put when its size changes.
    private var onlineIndicatorInset: CGFloat {
        max(0, self.size * 0.1854 - self.onlineIndicatorSize / 2)
    }
}

private struct PulsoAvatarMask: Shape {
    let cutsOutOnlineIndicator: Bool
    let indicatorSize: CGFloat
    let indicatorInset: CGFloat
    let indicatorGap: CGFloat

    func path(in rect: CGRect) -> Path {
        let avatar = Path(ellipseIn: rect)
        guard self.cutsOutOnlineIndicator else { return avatar }

        let cutoutRadius = self.indicatorSize / 2 + self.indicatorGap
        let indicatorCenter = CGPoint(
            x: rect.maxX - self.indicatorInset - self.indicatorSize / 2,
            y: rect.maxY - self.indicatorInset - self.indicatorSize / 2
        )
        // Subtract instead of an even-odd fill. The cutout reaches past the edge of
        // the avatar, and even-odd turns that overhang into an opaque region: the
        // corner of the photo would show up outside the circle, next to the badge.
        return avatar.subtracting(Path(ellipseIn: CGRect(
            x: indicatorCenter.x - cutoutRadius,
            y: indicatorCenter.y - cutoutRadius,
            width: cutoutRadius * 2,
            height: cutoutRadius * 2
        )))
    }
}

private struct NativeTrackedAppIcon: View {
    let url: String?
    var size: CGFloat = 28

    var body: some View {
        LazyImage(url: url.flatMap(URL.init(string:))) { state in
            if let image = state.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "app")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
                    .padding(size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
