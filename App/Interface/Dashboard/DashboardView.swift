import Charts
import SwiftUI

struct DashboardView: View {
    // MARK: Internal

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeaderView(
                groups: self.$viewModel.groups,
                selectedGroup: self.$viewModel.selectedGroup,
                timeFilter: self.$viewModel.filter,
                onSettings: self.viewModel.openSettings
            )

            DashboardUsersView(users: self.viewModel.leaderboard)
        }
    }

    // MARK: Private

    @StateObject private var viewModel = DashboardViewModel()
}

// Safe array subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
