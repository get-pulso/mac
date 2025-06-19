import Charts
import SwiftUI

struct DashboardView: View {
    // MARK: Internal

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                DashboardHeaderView(
                    groups: self.$viewModel.groups,
                    selectedGroup: self.$viewModel.selectedGroup,
                    timeFilter: self.$viewModel.filter,
                    onSettings: self.viewModel.openSettings,
                    onGroupAdd: self.viewModel.openWebClient
                )

                DashboardUsersView(users: self.viewModel.leaderboard)
            }
            // Bottom right, smaller Invite button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    DashboardInviteButon(action: self.viewModel.openWebClient)
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: Private

    @StateObject private var viewModel = DashboardViewModel()
}
