import AppKit
import Darwin
import Security

enum AppLaunchGuard {
    // MARK: Internal

    static let expectedTeamIdentifier = "25UG4QYN9F"

    @MainActor
    static func validateSigning() -> Bool {
        guard self.currentTeamIdentifier() == self.expectedTeamIdentifier else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Firstlight is not signed correctly"
            alert.informativeText = "Build and run Firstlight with Scripts/run-local-signed.sh."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            return false
        }
        return true
    }

    @MainActor
    static func acquireSingleInstanceLock() -> Bool {
        var lockName = "\(self.bundleIdentifier).instance.lock"
        #if DEBUG
        // A preview is its own process beside the real app, never a second
        // instance of it: it gets its own lock and leaves the user's alone.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--preview-") }) {
            lockName = "\(self.bundleIdentifier).preview.lock"
            // Two sessions previewing at once each name their own lock, so
            // neither has to wait for, or close, the other's window.
            let arguments = CommandLine.arguments
            if let flag = arguments.firstIndex(of: "--preview-lock"), flag + 1 < arguments.count {
                let name = arguments[flag + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
                if !name.isEmpty { lockName = "\(self.bundleIdentifier).preview.\(name).lock" }
            }
        }
        #endif
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(lockName)
            .path
        let descriptor = open(path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return false }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            self.activateExistingInstance()
            return false
        }

        self.lockDescriptor = descriptor
        return true
    }

    // MARK: Private

    private static var lockDescriptor: Int32 = -1

    private static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "sh.firstlight.mac"

    private static func currentTeamIdentifier() -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        ) == errSecSuccess,
            let staticCode
        else { return nil }

        var signingInformation: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &signingInformation) == errSecSuccess,
              let information = signingInformation as NSDictionary?
        else { return nil }

        return information[kSecCodeInfoTeamIdentifier] as? String
    }

    @MainActor
    private static func activateExistingInstance() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID })?
            .activate()
    }
}
