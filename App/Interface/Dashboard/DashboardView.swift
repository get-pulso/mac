import SwiftUI

struct DashboardView: View {
    @StateObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(time: self.$viewModel.todayTime, onTerminate: self.viewModel.terminate)
            ActivityView(activities: self.$viewModel.todayActivities)
        }
        .frame(width: 290)
        .frame(minHeight: 300)
    }
}
