import Dependencies
import SwiftUI

final class LoginViewModel: ObservableObject {
    // MARK: Internal

    @Published var isWaitingForLogin: Bool = false

    func startLogin() {
        withAnimation {
            self.isWaitingForLogin = true
        }

        self.appRouter.hide()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(self.handleAppleEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )

        let webURL = URL(string: "https://www.pulso.sh/mac-login")!
        NSWorkspace.shared.open(webURL)

        // timeout for login to reset ui
        Task { [weak self] in
            try await Task.sleep(for: .seconds(180))

            await MainActor.run { [weak self] in
                guard self?.isWaitingForLogin == true else { return }

                self?.isWaitingForLogin = false
            }
        }
    }

    // MARK: Private

    @Dependency(\.appRouter) private var appRouter: AppRouter
    @Dependency(\.auth) private var auth: Auth
    @Dependency(\.network) private var network: Network

    @objc private func handleAppleEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "pulso",
              components.host == "auth",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else { return }

        Task {
            self.appRouter.show()

            do {
                let response = try await self.network.verify(loginToken: token)
                try await self.auth.update(
                    jwtToken: response.jwt,
                    refreshToken: response.refreshToken
                )
                await MainActor.run {
                    try? self.appRouter.dashboard()
                    NSAppleEventManager.shared().removeEventHandler(
                        forEventClass: AEEventClass(kInternetEventClass),
                        andEventID: AEEventID(kAEGetURL)
                    )
                }
            } catch {
                await MainActor.run {
                    self.isWaitingForLogin = false
                }
            }
        }
    }
}
