import Dependencies
import SwiftUI

struct UpdateSettingsView: View {
    // MARK: Internal

    @ObservedObject var updater: Updater
    var enabled = !AppEnvironment.isLocalBackend

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Firstlight updates")
                    Text(self.message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                self.actions.nativeSettingsActionButton()
            }
            switch self.updater.state {
            case .checking,
                 .installing: ProgressView().controlSize(.small)
            case let .downloading(progress),
                 let .extracting(progress):
                if let progress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
            default: EmptyView()
            }
        }
    }

    // MARK: Private

    @Environment(\.openURL) private var openURL

    private var message: String {
        switch self.updater.state {
        case .idle: self.enabled ? "Updates install automatically." : "Updates are off in local development."
        case .checking: "Checking for updates…"
        case .upToDate: "You're up to date."
        case .permission: "Allow Firstlight to check for updates automatically?"
        case let .available(version): "Firstlight \(version) is available."
        case .downloading: "Downloading update…"
        case .extracting: "Preparing update…"
        case .ready: "Ready to restart and update."
        case .installing: "Restarting Firstlight…"
        case .waitingToQuit: "Restart to finish updating. Save any pending changes first."
        case .information: "A new version requires a manual download."
        case let .failed(message): message
        }
    }

    @ViewBuilder private var actions: some View {
        switch self.updater.state {
        case .available:
            Button("Update") { self.updater.installUpdate() }
        case .ready,
             .waitingToQuit:
            Button("Restart") { self.updater.installUpdate() }
        case .checking,
             .downloading:
            Button("Cancel") { self.updater.cancel() }.disabled(!self.updater.canCancel)
        case .extracting,
             .installing: EmptyView()
        case .permission:
            Button("Not now") { self.updater.allowAutomaticChecks(false) }
            Button("Allow") { self.updater.allowAutomaticChecks(true) }
        case let .information(url):
            if let url { Button("View update") { self.openURL(url) } }
        default:
            Button("Check now") { self.updater.checkForUpdates() }.disabled(!self.enabled)
        }
    }
}
