import Charts
import SwiftUI

struct DashboardView: View {
    @StateObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeaderView(
                timeData: self.$viewModel.timeData,
                onTerminate: self.viewModel.terminate
            )
            DashboardChartView(data: self.viewModel.weeklyChartData)
        }
        .frame(width: 290)
    }
}
