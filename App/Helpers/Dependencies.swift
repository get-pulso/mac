import Dependencies

extension Tracker: DependencyKey {
    static let liveValue = Tracker(
        storage: .liveValue,
        network: .liveValue
    )
}

extension Storage: DependencyKey {
    static let liveValue = Storage()
}

extension Auth: DependencyKey {
    static let liveValue = Auth()
}

extension Network: DependencyKey {
    static let liveValue = Network(auth: .liveValue)
}

extension Updater: DependencyKey {
    static let liveValue = Updater()
}

extension AppRouter: DependencyKey {
    static let liveValue = AppRouter()
}

extension WindowManager: DependencyKey {
    static let liveValue = WindowManager()
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

    var auth: Auth {
        get { self[Auth.self] }
        set { self[Auth.self] = newValue }
    }

    var network: Network {
        get { self[Network.self] }
        set { self[Network.self] = newValue }
    }

    var updater: Updater {
        get { self[Updater.self] }
        set { self[Updater.self] = newValue }
    }

    var windowManager: WindowManager {
        get { self[WindowManager.self] }
        set { self[WindowManager.self] = newValue }
    }
}
