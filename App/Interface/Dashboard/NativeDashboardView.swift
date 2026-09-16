import Defaults
import Dependencies
import NukeUI
import SwiftUI

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
                    PopoverContent {
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

    @ObservedObject private var store = SocialStore.shared
    @ObservedObject private var session = NativeSession.shared
    @Dependency(\.windowManager) private var windowManager
    @State private var confirming = false
    @State private var confirmationTitle = ""
    @State private var confirmationAction: (() -> Void)?
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var needsInitialLoad: Bool {
        if self.store.screen == .connect { return false }
        return self.store.screenLoading && !self.store.hasLoaded(self.store.screen)
    }

    private var isPersonScreen: Bool {
        if case .person = self.store.screen { return true }
        return false
    }

    private var header: some View {
        HStack(spacing: 6) {
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
                }.scrollIndicators(.hidden)
                    .onChange(of: store.tab) { _, value in withAnimation { reader.scrollTo(value, anchor: .center) } }
            }
            Menu {
                Button("Add friends") { store.openConnect(.useInvite) }
                Button("Friend requests") { store.open(.requests) }
                Divider()
                Button("New group") { SettingsWindowController.shared.show(section: .groups, groupsPage: .create) }
                Button("Manage groups") { SettingsWindowController.shared.show(section: .groups) }
            } label: { Image(systemName: "plus").font(.system(size: 17)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26, height: 30)
                .help("Add friends and groups")
            Button { SettingsWindowController.shared.show() } label: {
                Image(systemName: "gearshape").font(.system(size: 16)).frame(width: 26, height: 30)
            }.buttonStyle(.plain).help("Settings").keyboardShortcut(",", modifiers: .command)
        }.padding(.horizontal, 12).frame(height: NativeLayout.popoverHeaderHeight)
    }

    private var subheader: some View {
        HStack(spacing: 10) {
            NativeBackButton(help: "Back to \(backDestinationTitle)") { store.goBack() }
            Text(screenTitle).font(.system(size: 13, weight: .medium))
            Spacer()
        }.padding(.horizontal, 12).frame(height: NativeLayout.popoverHeaderHeight)
    }

    private var profileHeader: some View {
        HStack(spacing: 8) {
            NativeBackButton(help: "Back to \(backDestinationTitle)") { store.goBack() }
            Spacer()
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
            Text(scopeSummary).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Picker("Period", selection: $store.period) {
                Text("24 hours").tag("24h"); Text("7 days").tag("7d"); Text("30 days").tag("30d")
            }.labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
        }.padding(.horizontal, 13).frame(height: NativeLayout.peopleFooterHeight)
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
                        action: { Task { await store.refresh() } }
                    )
                case .empty:
                    NativeStateMessage(
                        title: "No activity yet",
                        message: store.tab == "global" ? "No activity for this period." :
                            "Invite a friend or join a group to get started.",
                        actionTitle: store.tab == "global" ? nil : "Invite a friend",
                        action: store.tab == "global" ? nil : { store.openConnect(.shareMine) }
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
                            Divider().padding(.leading, 65).opacity(0.55)
                        }
                    }
                    if listPhase == .failedWithContent {
                        NativeInlineError(message: store.listError ?? "Couldn't refresh activity") {
                            Task { await store.refresh() }
                        }.padding(12)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var listPhase: ContentLoadPhase {
        ContentLoadPhase.resolve(
            isLoading: self.store.loading,
            hasContent: !self.store.people.isEmpty,
            hasError: self.store.listError != nil
        )
    }

    private var scopeSummary: String {
        if self.store.loading, self.store.people.isEmpty { return "Loading activity…" }
        let count = self.store.people.count
        if self.store.tab == "global" { return count == 1 ? "1 person" : "\(count) people" }
        if self.store.tab == "friends" {
            let friends = self.store.people.filter { $0.id != Defaults[.currentUserID] }.count
            return friends == 1 ? "1 friend" : "\(friends) friends"
        }
        return count == 1 ? "1 member" : "\(count) members"
    }

    @ViewBuilder private var detailSkeleton: some View {
        switch store.screen {
        case .connect:
            NativeMetricSkeleton()
        case .requests:
            NativeRowsSkeleton(rows: 3, showActions: true)
        case .history:
            NativeRowsSkeleton(rows: 4)
        case .tokens:
            NativeMetricSkeleton()
        default:
            NativeMetricSkeleton()
        }
    }

    @ViewBuilder private var content: some View {
        switch store.screen {
        case .list: EmptyView()
        case .connect: connectForm
        case .requests:
            sectionHeading("Incoming")
            if store.requests.incoming.isEmpty { quiet("No incoming requests.") }
            ForEach(store.requests.incoming) { request in
                if let person = request.requester {
                    requestRow(person, detail: "Wants to be friends") {
                        operationButton(
                            "Accept",
                            loadingTitle: "Accepting…",
                            key: "accept-request-\(request.id)",
                            prominent: true
                        ) { store.respond(request.id, action: "accept") }
                        operationButton(
                            "Decline",
                            loadingTitle: "Declining…",
                            key: "decline-request-\(request.id)"
                        ) { store.respond(request.id, action: "decline") }
                    }
                }
            }
            Divider()
            sectionHeading("Sent")
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
        case .tokens:
            if let result = store.tokens {
                intro(
                    "\(result.tokens.current) of \(result.tokens.maxBalance) tokens",
                    message: "\(result.tokens.totalEarned) earned in total. Tokens are used when invitations are accepted."
                )
                if result.tokens.canGetRescueToken {
                    operationButton("Get a rescue token", loadingTitle: "Getting token…", key: "rescue-token") {
                        store.rescueToken()
                    }
                }
                if let remaining = result.tokens.nextRescueTokenIn { quiet("Next rescue token in \(remaining).") }
                if !result.pendingActivations.isEmpty {
                    Divider(); sectionHeading("Awaiting activation")
                    ForEach(result.pendingActivations) { activation in
                        valueRow(
                            activation.users?.name ?? activation.users?.email ?? "Invited friend",
                            value: "Pending"
                        )
                    }
                }
                Divider(); sectionHeading("Recent activity")
                if result.transactions.isEmpty { quiet("No token activity yet.") }
                ForEach(result.transactions) { transaction in
                    valueRow(
                        transaction.reason.replacingOccurrences(of: "_", with: " ").capitalized,
                        detail: transaction.created_at.map(readableDate),
                        value: "\(transaction.amount > 0 ? "+" : "")\(transaction.amount)"
                    )
                }
            }
        case let .person(id): personDetail(id)
        case .history:
            intro("Invitation history", message: "Previously created direct and group invitations.")
            if store.inviteHistory.isEmpty {
                NativeStateMessage(title: "No invitations yet", message: "Created links will appear here.")
            }
            ForEach(store.inviteHistory) { invite in
                valueRow(
                    invite.groups?.name ?? "Personal invitation",
                    detail: invite
                        .used == true ? "Used" : "\(invite.usage_count ?? 0) of \(invite.usage_limit ?? 1) uses"
                ) {
                    Button("Copy") { store.copy(AppEnvironment.inviteLink(for: invite.token)) }
                }
            }
            Divider()
            navigationRow("Invitation tokens", detail: "Balance and recent use") { store.open(.tokens) }
        }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            connectModeTabs

            if store.connectMode == .useInvite { useInviteForm }
            else { shareInviteForm }
        }
    }

    @ViewBuilder private var connectModeTabs: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    liquidGlassConnectModeTab("Use invite", mode: .useInvite)
                    liquidGlassConnectModeTab("Share mine", mode: .shareMine)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Add friends method")
        } else {
            HStack(spacing: 3) {
                connectModeTab("Use invite", mode: .useInvite)
                connectModeTab("Share mine", mode: .shareMine)
            }
            .padding(3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Add friends method")
        }
    }

    private var shareInviteForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            intro("Your invite", message: "Show the code nearby, or send the same invite as a link.")
            if let invite = store.personalInvite {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FRIEND CODE").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(displayFriendCode(invite.personalInviteCode))
                            .font(.system(size: 26, weight: .medium, design: .monospaced))
                            .tracking(1.5).lineLimit(1).minimumScaleFactor(0.68).textSelection(.enabled)
                            .accessibilityLabel("Friend code \(invite.personalInviteCode)")
                        Spacer(minLength: 4)
                        Button(store.copiedItem == .friendCode ? "Copied" : "Copy code") {
                            store.copyFriendCode(invite.personalInviteCode)
                        }.controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if store.screenLoading {
                NativeDelayedSkeleton {
                    VStack(alignment: .leading, spacing: 10) {
                        NativeSkeletonShape(width: 108, height: 13)
                        HStack(spacing: 10) {
                            NativeSkeletonShape(width: 154, height: 28, radius: 5)
                            Spacer()
                            NativeSkeletonShape(width: 68, height: 22, radius: 6)
                        }
                    }.padding(12)
                }
            }
            field("Invite to") {
                Picker("Invite to", selection: $store.inviteGroup) {
                    Text("Friends").tag("")
                    ForEach(store.groups) { Text($0.name).tag($0.id) }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity)
            }
            if !store.inviteGroup
                .isEmpty { Stepper("Uses: \(store.usageLimit)", value: $store.usageLimit, in: 1 ... 100) }
            primary(
                store.copiedItem == .inviteLink ? "Copied" : "Copy invite link",
                loadingTitle: "Creating link…",
                key: "create-invite",
                fillsWidth: true,
                action: store.shareInvite
            ).disabled(store.inviteGroup.isEmpty && store.personalInvite == nil)
            Divider()
            navigationRow("Invitation history", detail: "Previously created links") { store.open(.history) }
        }
        .onChange(of: store.inviteGroup) { _, _ in store.clearGeneratedInvite() }
        .onChange(of: store.usageLimit) { _, _ in store.clearGeneratedInvite() }
    }

    private var useInviteForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            intro("Use their invite", message: "Paste a Pulso link or enter any friend code.")
            field("Link or code") {
                TextField("Paste a link or enter a code", text: $store.input).labelsHidden()
                    .onChange(of: store.input) { _, _ in store.inviteInfo = nil; store.notice = nil }
            }
            if !store.canAcceptInvite {
                primary(
                    "Check invite",
                    loadingTitle: "Checking…",
                    key: "inspect-invite",
                    fillsWidth: true,
                    action: store.inspectInvite
                ).disabled(store.input.isEmpty)
            }
            if let info = store.inviteInfo {
                Divider()
                intro(
                    info.invite.groupName,
                    message: "Invited by \(info.invite.inviterName). \(info.invite.memberCount) members."
                )
            } else if store.canAcceptInvite, store.inspectedInviteIsFriendCode {
                Divider()
                intro("Friend request", message: "The code owner will choose whether to accept.")
            }
            if store.canAcceptInvite {
                quiet("Continue as \(session.user?.primaryEmailAddress?.emailAddress ?? "your current account").")
                primary(
                    store.inspectedInviteIsFriendCode ? "Send friend request" : "Accept invitation",
                    loadingTitle: store.inspectedInviteIsFriendCode ? "Sending…" : "Joining…",
                    key: "accept-invite",
                    fillsWidth: true,
                    action: store.acceptInvite
                )
                Button {
                    confirm("Sign out and accept this invitation with another account?") {
                        session.pendingInvite = store.input
                        store.run("Signing out…", key: "switch-account") { try await session.signOut() }
                    }
                } label: {
                    NativeAsyncButtonLabel(
                        title: "Use another account…",
                        loadingTitle: "Signing out…",
                        isLoading: store.isRunning("switch-account")
                    )
                }.disabled(store.busy)
                Button("Cancel", action: store.declineInvite)
            }
        }
    }

    private var screenTitle: String {
        self.screenTitle(for: self.store.screen)
    }

    private var backDestinationTitle: String {
        self.screenTitle(for: self.store.previousScreen ?? .list)
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
                store.showList(notice: "Friend removed.")
                await store.refresh()
            }
        }
    }

    @available(macOS 26.0, *)
    private func liquidGlassConnectModeTab(_ title: String, mode: SocialStore.ConnectMode) -> some View {
        let selected = self.store.connectMode == mode
        return Button {
            withAnimation(.snappy(duration: 0.24)) { self.store.connectMode = mode }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .glassEffect(
            selected ? .regular.tint(Color.primary.opacity(0.10)).interactive() : .clear.interactive(),
            in: .rect(cornerRadius: 10)
        )
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func connectModeTab(_ title: String, mode: SocialStore.ConnectMode) -> some View {
        let selected = self.store.connectMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { self.store.connectMode = mode }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
                .background(
                    selected ? Color.primary.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func screenTitle(for screen: SocialStore.Screen) -> String {
        switch screen {
        case .list: "Friends"
        case .connect: "Add friends"
        case .requests: "Friend requests"
        case .person: "Profile"
        case .history: "Invitations"
        case .tokens: "Invitation tokens"
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
        HStack(spacing: 10) {
            PulsoAvatar(
                url: person.avatar_url,
                name: person.displayName,
                size: 40,
                showsOnlineIndicator: person.id == Defaults[.currentUserID] || person.isActiveNow
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(person.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if person
                        .id ==
                        Defaults[.currentUserID] { Text("you").foregroundStyle(.tertiary).font(.system(size: 11)) }
                    Spacer(minLength: 4)
                    AnimatedDuration(minutes: person.active_minutes ?? 0)
                        .foregroundStyle(.secondary).font(.system(size: 12))
                    if let activeApp = person.active_app, person.isActiveNow {
                        NativeTrackedAppIcon(url: activeApp.icon_url, size: 16)
                            .help(activeApp.name)
                    }
                }
                let subtitle = [person.location, person.bio].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .multilineTextAlignment(.leading)
                }
            }
        }.padding(.horizontal, 13).padding(.vertical, 10).contentShape(Rectangle())
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
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5) }

                Text(person.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)

                let identity = [person.location, id == Defaults[.currentUserID] ? "You" : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !identity.isEmpty {
                    Text(identity).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            if [person.website, person.twitter, person.telegram].contains(where: { $0?.isEmpty == false }) {
                HStack(spacing: 18) {
                    profileLink("Website", systemImage: "globe", raw: person.website)
                    profileLink(
                        "X",
                        systemImage: "at",
                        raw: person.twitter.map { $0.hasPrefix("https://") ? $0 : "https://x.com/\($0)" }
                    )
                    profileLink(
                        "Telegram",
                        systemImage: "paperplane.fill",
                        raw: person.telegram.map { $0.hasPrefix("https://") ? $0 : "https://t.me/\($0)" }
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }

            if let bio = person.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(bio)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
            }

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
            if let activeApp = store.activity?.active_app {
                Divider()
                self.sectionHeading("Active now")
                self.trackedAppRow(activeApp, showsActiveState: true)
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

    @ViewBuilder private func profileLink(_ label: String, systemImage: String, raw: String?) -> some View {
        if let raw, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") {
            VStack(spacing: 5) {
                if #available(macOS 26.0, *) {
                    Link(destination: url) {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                } else {
                    Link(destination: url) {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                }
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
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

    private func readableDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter
            .formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value))?
            .formatted(date: .abbreviated, time: .shortened) ?? value
    }

    private func contact(_ person: NativeContact) -> some View {
        HStack(spacing: 10) {
            PulsoAvatar(url: person.avatar_url, name: person.displayName, size: 32)
            Text(person.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
    }

    private func contact(_ person: NativePerson) -> some View {
        HStack(spacing: 10) {
            PulsoAvatar(url: person.avatar_url, name: person.displayName, size: 32)
            Text(person.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
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

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
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

    private func valueRow(_ title: String, detail: String? = nil, value: String) -> some View {
        self.valueRow(title, detail: detail) {
            Text(value).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func valueRow(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            actions()
        }.padding(.vertical, 3)
    }

    private func quiet(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func primary(
        _ title: String,
        loadingTitle: String? = nil,
        key: String? = nil,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        if fillsWidth {
            if #available(macOS 26.0, *) {
                Button(action: action) {
                    primaryLabel(title, loadingTitle: loadingTitle, key: key)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .contentShape(Rectangle())
                }
                .controlSize(.large)
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
                .disabled(store.busy)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(action: action) {
                    primaryLabel(title, loadingTitle: loadingTitle, key: key)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(self.store.busy)
                .keyboardShortcut(.defaultAction)
            }
        } else {
            HStack {
                Spacer()
                Button(action: action) { primaryLabel(title, loadingTitle: loadingTitle, key: key) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func primaryLabel(_ title: String, loadingTitle: String?, key: String?) -> some View {
        NativeAsyncButtonLabel(
            title: title,
            loadingTitle: loadingTitle ?? title,
            isLoading: key.map(self.store.isRunning) ?? false
        )
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
        self.store.openConnect(.useInvite); self.store.input = value
    }

    private func refreshVisibleScreen() {
        guard self.windowManager.isVisible, !self.store.busy else { return }
        if self.store.screen == .list { Task { await store.refresh() } }
        else if case .person = self.store.screen, !self.store.screenLoading { store.open(store.screen) }
    }
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
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if showsOnlineIndicator {
                Circle().fill(Color.green)
                    .frame(width: max(8, size * 0.23), height: max(8, size * 0.23))
                    .overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 1, y: 1)
            }
        }
        .accessibilityHidden(true)
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
