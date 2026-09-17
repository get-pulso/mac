import Combine
import Foundation
import Sparkle

/// Sparkle owns checking, signatures and installation. Settings owns every
/// presentation, so a menu-bar app never strands a Sparkle window in another Space.
final class UpdateDriver: NSObject, SPUUserDriver {
    // MARK: Lifecycle

    init(checkTimeout: TimeInterval = 30) {
        self.checkTimeout = checkTimeout
        super.init()
    }

    // MARK: Internal

    enum State: Equatable {
        case idle, checking, upToDate, permission
        case available(String), downloading(Double?), extracting(Double?), ready, installing, waitingToQuit
        case information(URL?), failed(String)
    }

    let state = CurrentValueSubject<State, Never>(.idle)
    var focus: (() -> Void)?
    private(set) var cancellation: (() -> Void)?

    func install() {
        if let retryTermination = self.retryTermination {
            retryTermination()
            return
        }
        guard let reply = self.choice else { return }
        self.choice = nil
        self.state.send(self.state.value == .ready ? .installing : .downloading(nil))
        reply(.install)
    }

    func skip() {
        guard let reply = self.choice else { return }
        self.clearCallbacks()
        self.state.send(.idle)
        reply(.skip)
    }

    func cancel() {
        guard let cancel = self.cancellation else { return }
        self.clearCallbacks()
        self.state.send(.idle)
        cancel()
    }

    func allowAutomaticChecks(_ allowed: Bool) {
        guard let reply = self.permission else { return }
        self.permission = nil
        self.state.send(.idle)
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: allowed, sendSystemProfile: false))
    }

    func fail(_ error: Error) {
        self.clearCallbacks()
        self.state.send(.failed(error.localizedDescription))
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        self.permission = reply
        self.state.send(.permission)
        self.focus?()
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.clearCallbacks()
        self.cancellation = cancellation
        self.state.send(.checking)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state.value == .checking, let cancel = self.cancellation else { return }
            self.clearCallbacks()
            self.state.send(.failed("The update check timed out. Please try again."))
            cancel()
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + self.checkTimeout, execute: timeout)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        self.clearCallbacks()
        if appcastItem.isInformationOnlyUpdate {
            self.state.send(.information(appcastItem.infoURL))
            reply(.dismiss)
        } else {
            self.choice = reply
            self.state.send(state.stage == .installing ? .ready : .available(appcastItem.displayVersionString))
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        self.clearCallbacks()
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if reason?.intValue == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue) ||
            reason?.intValue == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue)
        {
            self.state.send(.upToDate)
        } else {
            self.state.send(.failed(error.localizedDescription))
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        self.fail(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.clearCallbacks()
        self.cancellation = cancellation
        self.expectedBytes = 0
        self.receivedBytes = 0
        self.state.send(.downloading(nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedBytes = expectedContentLength
        self.updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        self.receivedBytes += length
        self.updateDownloadProgress()
    }

    func showDownloadDidStartExtractingUpdate() {
        self.clearCallbacks()
        self.state.send(.extracting(nil))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        self.state.send(.extracting(min(1, max(0, progress))))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.clearCallbacks()
        self.choice = reply
        self.state.send(.ready)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        self.clearCallbacks()
        if applicationTerminated {
            self.state.send(.installing)
        } else {
            self.retryTermination = retryTerminatingApplication
            self.state.send(.waitingToQuit)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        self.clearCallbacks()
        self.state.send(.upToDate)
        acknowledgement()
    }

    func showUpdateInFocus() { self.focus?() }

    func dismissUpdateInstallation() {
        self.clearCallbacks()
        // Sparkle dismisses its session immediately after acknowledging a
        // no-update result or an error. Keep that result visible in Settings.
        switch self.state.value {
        case .upToDate,
             .failed,
             .information: break
        default: self.state.send(.idle)
        }
    }

    // MARK: Private

    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var permission: ((SUUpdatePermissionResponse) -> Void)?
    private var retryTermination: (() -> Void)?
    private var timeout: DispatchWorkItem?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private let checkTimeout: TimeInterval

    private func clearCallbacks() {
        self.timeout?.cancel()
        self.timeout = nil
        self.cancellation = nil
        self.choice = nil
        self.permission = nil
        self.retryTermination = nil
    }

    private func updateDownloadProgress() {
        let progress = self.expectedBytes > 0 ? min(1, Double(self.receivedBytes) / Double(self.expectedBytes)) : nil
        self.state.send(.downloading(progress))
    }
}
