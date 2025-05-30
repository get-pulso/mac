import SwiftUI

struct DashboardHeaderView: View {
    // MARK: Internal

    @Binding var timeData: DashboardViewModel.TimeData

    let onTerminate: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Today Time: ")
                        .font(.headline)
                    Text(self.formattedTime)
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText(countsDown: false))
                }
                HStack {
                    Text("Week Total: ")
                        .font(.subheadline)
                    Text(self.formattedWeekTime)
                        .font(.subheadline.monospacedDigit())
                        .contentTransition(.numericText(countsDown: false))
                }
            }
            Spacer()
            Button("Quit", role: .destructive, action: self.onTerminate)
        }
        .padding(12)
    }

    // MARK: Private

    private let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    private var formattedTime: String {
        self.formatter.string(from: self.timeData.today) ?? ""
    }

    private var formattedWeekTime: String {
        self.formatter.string(from: self.timeData.week) ?? ""
    }
}
