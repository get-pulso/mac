import Foundation

/// A verified account's display data, never credentials or a cached authorization decision.
struct WelcomeAccount: Equatable {
    // MARK: Lifecycle

    init(id: String, firstName: String?, fullName: String?, username: String?, avatarURL: String?) {
        self.id = id
        self.name = [firstName, fullName, username]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        self.avatarURL = avatarURL.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Internal

    let id: String
    let name: String?
    let avatarURL: String?

    var buttonTitle: String { self.name.map { "Continue as \($0)" } ?? "Continue to Firstlight" }
    /// The letter the sign-in button's portrait falls back on, the same one
    /// the portrait itself draws when there is no name: Firstlight's.
    var initial: String { AvatarMonogram.letter(for: self.name ?? "") ?? "F" }
}
