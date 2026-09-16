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

    /// Looks up the invitation in `text`, if it is one. A miss leaves Welcome
    /// as it would be without an invitation; the tray still handles the link.
    func load(_ text: String?) async {
        guard let text, let input = try? InviteInput.parse(text) else {
            self.inviter = nil
            return
        }
        @Dependency(\.network) var network
        switch input {
        case let .friendCode(code):
            guard let info: NativeJoinInfo = try? await network
                .request(path: "/api/join/\(code)", method: .get, auth: false)
            else { return }
            self.inviter = Inviter(
                name: info.invite.inviterName,
                avatarURL: info.invite.inviterAvatarUrl,
                destination: "Firstlight"
            )
        case let .token(token):
            guard let info: NativeInviteInfo = try? await network
                .request(path: "/api/invite/info", method: .get, auth: false, query: ["token": token])
            else { return }
            self.inviter = Inviter(
                name: info.invite.inviterName,
                avatarURL: info.invite.inviterAvatarUrl,
                destination: info.invite.isUniversal ? "Firstlight" : info.invite.groupName
            )
        }
    }
}
