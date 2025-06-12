import Charts
import SwiftUI

struct DashboardView: View {
    @StateObject var viewModel = try! DashboardViewModel()

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeaderView(
                timeData: self.$viewModel.timeData,
                onSettings: self.viewModel.openSettings
            )
            DashboardChartView(data: self.viewModel.weeklyChartData)
        }
    }
}
