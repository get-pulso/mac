import AppKit
import Darwin

let app = NSApplication.shared
let launchDecision = MainActor.assumeIsolated {
    guard AppLaunchGuard.validateSigning() else { return EX_CONFIG }
    return AppLaunchGuard.acquireSingleInstanceLock() ? EXIT_SUCCESS : EX_TEMPFAIL
}

guard launchDecision == EXIT_SUCCESS else {
    exit(launchDecision == EX_TEMPFAIL ? EXIT_SUCCESS : launchDecision)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
