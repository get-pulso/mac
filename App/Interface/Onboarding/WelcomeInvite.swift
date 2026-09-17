import Dependencies
import SwiftUI

/// Who is waiting on the other side of a pending invitation, looked up
/// before anyone is signed in, so Welcome can show the face that was in the
/// chat and on the arrival page instead of a generic greeting.
@MainActor
final class WelcomeInvite: ObservableObject {
    struct Inviter: Equatable {
        let name: String
        let avatarURL: String?
        /// "Firstlight" for a friend link, the group's name for a group link.
        let destination: String

        var firstName: String { self.name.split(separator: " ").first.map(String.init) ?? self.name }
        var isGroup: Bool { self.destination != "Firstlight" }
    }

    @Published private(set) var inviter: Inviter?
    /// The server answered and said no: the link has run its course. A
    /// transport failure is not this; it leaves Welcome generic and the tray
    /// still handles the link after sign-in.
    @Published private(set) var expired = false

    #if DEBUG
    /// What a preview wants Welcome to believe, and how late it should learn it.
    struct Fixture {
        var inviter: Inviter?
        var expired = false
        var delay: Double = 0
    }

    nonisolated(unsafe) static var fixture: Fixture?
    #endif

    /// Looks up the invitation in `text`, if it is one. A miss leaves Welcome
    /// as it would be without an invitation; the tray still handles the link.
    func load(_ text: String?) async {
        #if DEBUG
        if let fixture = Self.fixture {
            if fixture.delay > 0 { try? await Task.sleep(for: .seconds(fixture.delay)) }
            self.inviter = fixture.inviter
            self.expired = fixture.expired
            return
        }
        #endif
        guard let text, let input = try? InviteInput.parse(text) else {
            self.inviter = nil
            return
        }
        @Dependency(\.network) var network
        do {
            switch input {
            case let .friendCode(code):
                let info: NativeJoinInfo = try await network
                    .request(path: "/api/join/\(code)", method: .get, auth: false)
                self.inviter = Inviter(
                    name: info.invite.inviterName,
                    avatarURL: info.invite.inviterAvatarUrl,
                    destination: "Firstlight"
                )
            case let .token(token):
                let info: NativeInviteInfo = try await network
                    .request(path: "/api/invite/info", method: .get, auth: false, query: ["token": token])
                self.inviter = Inviter(
                    name: info.invite.inviterName,
                    avatarURL: info.invite.inviterAvatarUrl,
                    destination: info.invite.isUniversal ? "Firstlight" : info.invite.groupName
                )
            }
        } catch is NativeError {
            // The server itself refused the link: it is gone.
            self.expired = true
        } catch {}
    }
}
