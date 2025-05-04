import AppKit
import Combine
import Dependencies
import SwiftUI

final class DataProvider: ObservableObject {
    // MARK: Lifecycle

    init() throws {
        @Dependency(\.storage) var storage
        let activities = try storage.activity(in: .now)
        self.todayTime = activities.totalTime
        self.todayActivities = activities
        self.subscribeForActivities()
    }

    // MARK: Internal

    @Published var todayTime: Double
    @Published var todayActivities: [Activity]

    func terminate() {
        try? self.tracker.stop()
        NSApp.terminate(nil)
    }

    // MARK: Private

    @Dependency(\.tracker) private var tracker: Tracker
    @Dependency(\.storage) private var storage: Storage
    private var subcriptions = [AnyCancellable]()

    private func subscribeForActivities() {
        NotificationCenter.default.publisher(
            for: NSNotification.Name.NSCalendarDayChanged
        )
        .delay(for: 0.5, scheduler: DispatchQueue.main)
        .map { _ in Date.now }
        .prepend(Date.now)
        .flatMap { date in
            @Dependency(\.storage) var storage
            return storage.activityStream(in: date).ignoreError()
        }
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] activities in
            guard let self else { return }
            withAnimation {
                self.todayTime = activities.totalTime
                self.todayActivities = activities
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
