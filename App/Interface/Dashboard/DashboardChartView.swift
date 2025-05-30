import Charts
import SwiftUI

struct DashboardChartView: View {
    // MARK: Internal

    let data: [DashboardViewModel.ChartEntry]

    var body: some View {
        Chart(self.data) { entry in
            self.barMark(for: entry)
                .annotation(position: .top, alignment: .center) {
                    self.annotationView(for: entry)
                }
        }
        .frame(height: 120)
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let location = value.location
                                let chartData = self.data

                                // Get the x position for each data point
                                let positions = chartData.compactMap { entry -> (
                                    entry: DashboardViewModel.ChartEntry,
                                    x: CGFloat
                                )? in
                                    guard let x = proxy.position(forX: entry.day) else { return nil }
                                    return (entry, x)
                                }

                                // Find the closest bar to the tap location
                                if let closest = positions.min(by: { abs($0.x - location.x) < abs($1.x - location.x) })
                                {
                                    // If tapping the same bar, deselect it
                                    if let current = self.selectedEntry, current.id == closest.entry.id {
                                        self.selectedEntry = nil
                                    } else {
                                        self.selectedEntry = closest.entry
                                    }
                                }
                            }
                    )
            }
        }
    }

    // MARK: Private

    @State private var selectedEntry: DashboardViewModel.ChartEntry?

    private let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    @ViewBuilder
    private func annotationView(for entry: DashboardViewModel.ChartEntry) -> some View {
        if let selected = selectedEntry, selected.id == entry.id, selected.duration > 0 {
            Text(self.formatter.string(from: selected.duration * 3600) ?? "")
                .font(.caption)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.windowBackgroundColor).opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 1)
                )
                .shadow(radius: 2)
        }
    }

    private func barMark(for entry: DashboardViewModel.ChartEntry) -> some ChartContent {
        BarMark(
            x: .value("Day", entry.day),
            y: .value("Time", entry.duration)
        )
        .foregroundStyle(entry.isToday ? Color.accentColor.opacity(0.5) : Color.accentColor)
        .cornerRadius(3)
    }
}
