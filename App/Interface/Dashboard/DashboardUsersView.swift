import Combine
import NukeUI
import SwiftUI

struct DashboardUsersView: View {
    let users: [DashboardUserItem]
    let scrollTop: AnyPublisher<Void, Never>

    var body: some View {
        ScrollViewReader { proxy in
            List {
                let needsPlaceholder = self.users.isEmpty
                let users: [DashboardUserItem] = needsPlaceholder ? .placeholder : self.users
                ForEach(Array(users.enumerated()), id: \ .element.id) { index, user in
                    if needsPlaceholder {
                        UserRow(user: user, rank: index + 1)
                            .listRowSeparator(index == users.count - 1 ? .hidden : .visible)
                            .redacted(reason: .placeholder)
                            .id(user.id)
                    } else {
                        UserRow(user: user, rank: index + 1)
                            .listRowSeparator(index == users.count - 1 ? .hidden : .visible)
                            .id(user.id)
                    }
                }

                // bottom inset
                Spacer()
                    .frame(height: 24)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .contentMargins(.top, 0)
            .scrollContentBackground(.hidden)
            .frame(height: 160)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Spacer().frame(height: 16)
            }
            .onReceive(self.scrollTop) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(self.users.first?.id, anchor: .top)
                }
            }
        }
    }
}

private struct UserRow: View {
    // MARK: Internal

    let user: DashboardUserItem
    let rank: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("\(self.rank)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 16, alignment: .leading)
                .animation(nil, value: self.rank)

            ZStack(alignment: .bottomTrailing) {
                LazyImage(url: self.user.avatar) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        DefaultAvatarView(identifier: self.user.id, size: 28)
                    }
                }
                .clipShape(Circle())
                .frame(width: 28, height: 28)

                if self.user.isOnline {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1)
                        )
                        .offset(x: 1, y: 1)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(self.user.name)
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()

            if
                let minutes = self.user.minutes,
                let formatted = self.formatter.string(from: Double(minutes * 60))
            {
                Text(formatted)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText(value: Double(minutes)))
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 8 }
        .alignmentGuide(.listRowSeparatorTrailing) { d in d.width - 6 }
        .listRowSeparatorTint(Color(NSColor.separatorColor))
    }

    // MARK: Private

    private let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()
}

private extension [DashboardUserItem] {
    static var placeholder: Self {
        [
            .init(id: "1", name: "Some long name", avatar: nil, minutes: 3000, lastActiveAt: nil),
            .init(id: "2", name: "Some long name", avatar: nil, minutes: 3000, lastActiveAt: nil),
            .init(id: "3", name: "Some long name", avatar: nil, minutes: 3000, lastActiveAt: nil),
        ]
    }
}
