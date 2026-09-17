import Alamofire
import AppKit
import Combine
import Foundation
import Sparkle

final class Updater {
    // MARK: Lifecycle

    init() {
        self.sparkleDelegate = SparkleDelegate()
        self.driver = Driver(hostBundle: .main, delegate: self.sparkleDelegate)
        self.updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self.driver,
            delegate: self.sparkleDelegate
        )

        // Keep this assignment for existing installs: older Firstlight versions persisted
        // automatic downloads as disabled in Sparkle's user defaults.
        self.updater.automaticallyDownloadsUpdates = true
    }

    // MARK: Internal

    enum Status {
        case upToDate
        case newVersionAvailable
    }

    var statusPublisher: AnyPublisher<Status, Never> {
        self.driver.pendingUpdateSubject
            .map {
                $0 == nil ? .upToDate : .newVersionAvailable
            }
            .eraseToAnyPublisher()
    }

    func start() {
        try? self.updater.start()
    }

    func installUpdate() {
        self.driver.pendingUpdateSubject.value?.actionCallback(.install)
    }

    func checkForUpdates() { self.updater.checkForUpdates() }

    func skipUpdate() {
        self.driver.pendingUpdateSubject.value?.actionCallback(.skip)
    }

    // MARK: Private

    private let sparkleDelegate: SparkleDelegate
    private let driver: Driver
    private let updater: SPUUpdater
}

private final class Driver: SPUStandardUserDriver, SPUStandardUserDriverDelegate {
    struct PendingUpdate {
        let appcast: SUAppcastItem
        let actionCallback: (SPUUserUpdateChoice) -> Void
    }

    let pendingUpdateSubject = CurrentValueSubject<PendingUpdate?, Never>(nil)

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let update = PendingUpdate(appcast: appcastItem, actionCallback: reply)
        self.pendingUpdateSubject.send(update)
    }

    override func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        super.showUpdaterError(error, acknowledgement: acknowledgement)
        self.pendingUpdateSubject.send(nil)
    }

    override func dismissUpdateInstallation() {
        super.dismissUpdateInstallation()
        self.pendingUpdateSubject.send(nil)
    }
}

private final class SparkleDelegate: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

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
