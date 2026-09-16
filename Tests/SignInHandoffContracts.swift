import Foundation

/// Source-order regression checks for the authentication boundary. Native menu
/// actions have separate executable checks; these never call Clerk or sign out.
@main
enum SignInHandoffContracts {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
        let session = try read("App/Services/NativeSession.swift")
        let completion = String(session.components(separatedBy: "func finishSignIn(")[1]
            .components(separatedBy: "func continueFromWelcome()")[0])
        let open = completion.range(of: "window.show()")!.lowerBound
        let request = completion.range(of: "try await network.userInfo()")!.lowerBound
        let account = completion.range(of: "Defaults[.currentUserID] = info.user.id")!.lowerBound
        expect(open < request, "The menu-bar panel must open before profile loading suspends")
        expect(request < account, "Account access must wait for verified server data")
        expect(completion.components(separatedBy: "window.show()").count == 2,
               "Completion must not reopen a dismissed panel")
        expect(completion.contains("router.move(to: .signInCompletion)"), "Completion has a dedicated panel route")
        expect(completion.contains("self.session?.id == sessionID, self.session?.status == .active"),
               "An old response cannot restore a signed-out account")
        let start = String(session.components(separatedBy: "func start()")[1]
            .components(separatedBy: "func token(")[0])
        expect(!start.contains("step = .complete"), "Restoration must not flash completed auth in welcome")
        let window = try read("App/Interface/Window/WindowManager.swift")
        expect(window.contains("router.destination == .signInCompletion"), "Pending profile can use the panel")
        let delegate = try read("App/AppDelegate.swift")
        let reopen = String(delegate.components(separatedBy: "func applicationShouldHandleReopen")[1]
            .components(separatedBy: "func applicationShouldTerminate")[0])
        expect(reopen.contains("self.windowManager.show()"),
               "Opening an already-running menu-bar app must restore its visible window")
        let replay = String(window.components(separatedBy: "func replayOnboarding()")[1]
            .components(separatedBy: "func show()")[0])
        expect(replay.contains("guard Self.canReplayOnboarding"), "Replay must not interrupt authentication")
        expect(replay.contains("OnboardingWindowController.shared.close()") && replay.contains("forceAnimation: true"),
               "Replay must restart even an already-visible welcome")
        expect(!replay.contains("signOut") && !replay.contains("Defaults["), "Replay must preserve the account")
        let view = try read("App/Interface/Login/SignInCompletionView.swift")
        expect(view.contains("session.finishSignIn()") && view.contains("windowManager.hide()"),
               "Completion can retry or be dismissed without returning to welcome")
        print("PASS: \(checks) sign-in handoff source contracts")
    }
}
