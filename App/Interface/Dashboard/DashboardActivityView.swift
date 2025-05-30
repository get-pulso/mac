import SwiftUI

struct DashboardActivityView: View {
    @Binding var activities: [Activity]

    var body: some View {
        ScrollViewReader { scroll in
            List {
                ForEach(self.activities, id: \.id) { activity in
                    EntryView(activity: activity)
                        .listRowSeparatorTint(.primary.opacity(0.1))
                }
            }
            .onChange(of: self.activities.map(\.id), initial: false) {
                guard let first = self.activities.first else { return }
                withAnimation {
                    scroll.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }
}

private struct EntryView: View {
    let activity: Activity

    var body: some View {
        HStack {
            Text(self.activity.startedAt, format: Date.FormatStyle().hour().minute())
                .font(.callout.monospacedDigit())
            Spacer()
            Text(" - ")
                .font(.callout.monospacedDigit())
            Spacer()
            Text(self.activity.endedAt, format: Date.FormatStyle().hour().minute())
                .font(.callout.monospacedDigit())
                .contentTransition(.numericText(countsDown: false))
        }
    }
}
