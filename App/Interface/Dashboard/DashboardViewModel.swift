import AppKit
import Combine
import Dependencies
import Foundation
import SwiftUI

final class DashboardViewModel: ObservableObject {
    // MARK: Lifecycle

    init() throws {
        @Dependency(\.storage) var storage
        let activities = try storage.activity(in: .now)
        let weekActivities = try storage.activity(inWeekOf: .now)
        self.timeData = TimeData(today: activities.totalTime, week: weekActivities.totalTime)
        self.weeklyChartData = Self.generateChartData(storage: storage)
        self.subscribeForActivities()

        #warning("Cleanup")
        Task {
            @Dependency(\.network) var network
            let user = try await network.userInfo()
            print("current user: \(user)")
        }
    }

    // MARK: Internal

    struct TimeData {
        let today: Double
        let week: Double
    }

    struct ChartEntry: Identifiable {
        let id: String
        let day: String
        let duration: Double
        let isToday: Bool
    }

    @Published var timeData: TimeData
    @Published private(set) var weeklyChartData: [ChartEntry]

    func terminate() {
        try? self.tracker.stop()
        NSApp.terminate(self)
    }

    // MARK: Private

    @Dependency(\.tracker) private var tracker: Tracker
    @Dependency(\.storage) private var storage: Storage
    private var subcriptions = [AnyCancellable]()

    private static func generateChartData(storage: Storage) -> [ChartEntry] {
        let calendar = Calendar.current
        let now = Date()
        let startOfWeek = calendar
            .date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        return (0 ..< 7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfWeek) else { return nil }
            let dayLabel = DateFormatter.shortWeekday.string(from: day)
            let activities = (try? storage.activity(in: day)) ?? []
            let duration = activities.totalTime
            let isToday = calendar.isDate(day, inSameDayAs: now)
            return ChartEntry(
                id: dayLabel,
                day: dayLabel,
                duration: duration / 3600,
                isToday: isToday
            )
        }
    }

    private func subscribeForActivities() {
        NotificationCenter.default.publisher(
            for: NSNotification.Name.NSCalendarDayChanged
        )
        .delay(for: 0.5, scheduler: DispatchQueue.main)
        .map { _ in Date.now }
        .prepend(Date.now)
        .flatMap { date in
            @Dependency(\.storage) var storage
            return Publishers.CombineLatest(
                storage.activityStream(in: date),
                storage.activityStream(inWeekOf: date)
            )
            .map { activities, weekActivities in
                TimeData(
                    today: activities.totalTime,
                    week: weekActivities.totalTime
                )
            }
            .ignoreError()
        }
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] timeData in
            guard let self else { return }
            withAnimation {
                self.timeData = timeData
                self.weeklyChartData = Self.generateChartData(storage: self.storage)
            }
        })
        .store(in: &self.subcriptions)
    }
}

private extension [Activity] {
    var totalTime: Double {
        self.reduce(0.0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
    }
}

private extension DateFormatter {
    static let shortWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("E")
        return formatter
    }()
}
