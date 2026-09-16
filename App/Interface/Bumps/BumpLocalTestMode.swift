import Foundation

/// Temporary local interaction loop. Never sends or writes as another account.
enum BumpLocalTestMode {
    static let echoDelay: TimeInterval = 10
    static let cooldown: TimeInterval = 20

    static var isEnabled: Bool {
        #if DEBUG
        AppEnvironment.isLocalBackend && !CommandLine.arguments.contains("--live-bumps")
        #else
        false
        #endif
    }
}
