import SwiftUI

struct HeaderView: View {
    // MARK: Internal

    @Binding var time: Double

    let onTerminate: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text("Today Time: ")
                .font(.headline)
            Text(self.formattedTime)
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText(countsDown: false))

            Spacer()

            Button("Quit", role: .destructive, action: self.onTerminate)
        }
        .padding(12)
    }

    // MARK: Private

    private let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    private var formattedTime: String {
        self.formatter.string(from: self.time) ?? ""
    }
}
