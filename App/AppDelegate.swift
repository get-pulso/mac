import Cocoa
import Combine
import Defaults
import Dependencies
import ServiceManagement
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: Internal

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if OnboardingPreview.showIfRequested() { return }
        #endif
        LaunchAtLogin.enableByDefaultIfNeeded()
        Defaults[.currentUserID] = nil
        self.tracker.activate()
        if !AppEnvironment.isLocalBackend { self.updater.start() }
        let appearance = UserDefaults.standard.string(forKey: "pulso.appearance") ?? "system"
        NSApp.appearance = appearance == "system" ? nil : NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        Defaults[.sessionCounter] += 1
        Task {
            self.appRouter.move(to: .login)
            await NativeSession.shared.start(presentDashboardOnRestore: false)

            // observing logout
            for await _ in await self.auth.invalidationPublisher.values {
                Defaults[.currentUserID] = nil
                try? self.storage.cleanFriendsStore()

                await MainActor.run {
                    self.appRouter.move(to: .login)
                    self.windowManager.show()
                }
            }
        }

        self.windowManager.configure()
        if !UserDefaults.standard.bool(forKey: OnboardingWindowController.introSeenKey) {
            self.windowManager.showWelcome()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        OnboardingWindowController.shared.close()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Task { await NativeSession.shared.handle(url) } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        self.windowManager.show()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SettingsWindowController.shared.confirmTermination() ? .terminateNow : .terminateCancel
    }

    // MARK: Private

    @Dependency(\.auth) private var auth
    @Dependency(\.storage) private var storage
    @Dependency(\.tracker) private var tracker
    @Dependency(\.appRouter) private var appRouter
    @Dependency(\.updater) private var updater
    @Dependency(\.windowManager) private var windowManager
}

@MainActor
enum LaunchAtLogin {
    // MARK: Internal

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func enableByDefaultIfNeeded() {
        guard UserDefaults.standard.object(forKey: self.configuredKey) == nil else { return }
        UserDefaults.standard.set(true, forKey: self.configuredKey)
        guard self.status == .notRegistered || self.status == .notFound else { return }
        try? SMAppService.mainApp.register()
    }

    static func setEnabled(_ enabled: Bool) throws {
        UserDefaults.standard.set(true, forKey: self.configuredKey)
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Private

    private static let configuredKey = "pulso.launchAtLoginConfigured"
}
