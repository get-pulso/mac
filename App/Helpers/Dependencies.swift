import Dependencies

extension Tracker: DependencyKey {
    static let liveValue = Tracker(storage: .liveValue)
}

extension Storage: DependencyKey {
    static let liveValue = Storage()
}

extension AppRouter: DependencyKey {
    static let liveValue = AppRouter()
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

    var appRouter: AppRouter {
        get { self[AppRouter.self] }
        set { self[AppRouter.self] = newValue }
    }
}
