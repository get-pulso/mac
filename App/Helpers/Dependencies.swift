import Dependencies

extension Tracker: DependencyKey {
    static let liveValue = Tracker(storage: .liveValue)
}

extension Storage: DependencyKey {
    static let liveValue = Storage()
}

extension DependencyValues {
    var tracker: Tracker {
        get { self[Tracker.self] }
        set { self[Tracker.self] = newValue }
    }

    var storage: Storage {
        get { self[Storage.self] }
        set { self[Storage.self] = newValue }
    }
}
