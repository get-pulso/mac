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
            alert.messageText = "Pulso is not signed correctly"
            alert.informativeText = "Build and run Pulso with Scripts/run-local-signed.sh."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            return false
        }
        return true
    }

    @MainActor
    static func acquireSingleInstanceLock() -> Bool {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.get-pulso.mac.instance.lock")
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
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.get-pulso.mac")
            .first(where: { $0.processIdentifier != currentPID })?
            .activate()
    }
}
