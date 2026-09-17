import AppKit
import Combine
import Foundation
import Sparkle

final class Updater: ObservableObject {
    // MARK: Lifecycle

    init() {
        self.sparkleDelegate = SparkleDelegate()
        self.driver = UpdateDriver()
        self.updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self.driver,
            delegate: self.sparkleDelegate
        )

        // Keep this assignment for existing installs: older Firstlight versions persisted
        // automatic downloads as disabled in Sparkle's user defaults.
        self.updater.automaticallyDownloadsUpdates = true
        self.observation = self.driver.state.sink { [weak self] in self?.state = $0 }
        self.driver.focus = { Task { @MainActor in SettingsWindowController.shared.show(section: .about) } }
    }

    // MARK: Internal

    enum Status {
        case upToDate
        case newVersionAvailable
    }

    @Published private(set) var state: UpdateDriver.State = .idle

    var canCancel: Bool { self.driver.cancellation != nil }

    var statusPublisher: AnyPublisher<Status, Never> {
        self.driver.state
            .map { state in
                switch state {
                case .available,
                     .ready: .newVersionAvailable
                default: .upToDate
                }
            }
            .eraseToAnyPublisher()
    }

    func start() {
        guard !self.started else { return }
        do {
            try self.updater.start()
            self.started = true
        } catch {
            self.driver.fail(error)
        }
    }

    func installUpdate() {
        self.driver.install()
    }

    func checkForUpdates() {
        self.start()
        guard self.started else { return }
        self.updater.checkForUpdates()
    }

    func cancel() { self.driver.cancel() }

    func allowAutomaticChecks(_ allowed: Bool) { self.driver.allowAutomaticChecks(allowed) }

    func skipUpdate() {
        self.driver.skip()
    }

    // MARK: Private

    private let sparkleDelegate: SparkleDelegate
    private let driver: UpdateDriver
    private let updater: SPUUpdater
    private var observation: AnyCancellable?
    private var started = false
}

private final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        false
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock installHandler: @escaping () -> Void
    ) -> Bool {
        // Firstlight has no document workflow. Once Sparkle has downloaded, verified,
        // and prepared an update, install it immediately instead of waiting for
        // this menu-bar app to be quit manually.
        DispatchQueue.main.async { installHandler() }
        return true
    }
}
