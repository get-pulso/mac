import NukeUI
import SwiftUI

struct DashboardUsersView: View {
    let users: [DashboardUserItem]

    var body: some View {
        List {
            let needsPlaceholder = self.users.isEmpty
            let users: [DashboardUserItem] = needsPlaceholder ? .placeholder : self.users
            ForEach(Array(users.enumerated()), id: \ .element.id) { index, user in
                if needsPlaceholder {
                    UserRow(user: user)
                        .listRowSeparator(index == users.count - 1 ? .hidden : .visible)
                        .redacted(reason: .placeholder)
                } else {
                    UserRow(user: user)
                        .listRowSeparator(index == users.count - 1 ? .hidden : .visible)
                }
            }

            // bottom inset
            Spacer()
                .frame(height: 24)
                .listRowSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .frame(height: 160)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Spacer().frame(height: 16)
        }
    }
}

private struct UserRow: View {
    // MARK: Internal

    let user: DashboardUserItem

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                LazyImage(url: self.user.avatar) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
                .clipShape(Circle())
                .frame(width: 28, height: 28)

                if self.user.isOnline {
                    Circle()
                        .fill(Color.accentColor)
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
            .init(id: "1", name: "Some long name", avatar: nil, minutes: 3000, updatedAt: nil),
            .init(id: "2", name: "Some long name", avatar: nil, minutes: 3000, updatedAt: nil),
            .init(id: "3", name: "Some long name", avatar: nil, minutes: 3000, updatedAt: nil),
            .init(id: "4", name: "Some long name", avatar: nil, minutes: 3000, updatedAt: nil),
            .init(id: "5", name: "Some long name", avatar: nil, minutes: 3000, updatedAt: nil),
            .init(id: "6", name: "Some long name", avatar: nil, minutes: 3000, updatedAt: nil),
            .init(id: "7", name: "Some long name", avatar: nil, minutes: 3000, updatedAt: nil),
            .init(id: "8", name: "Some long name", avatar: nil, minutes: 3000, updatedAt: nil),
        ]
    }
}
