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
    var initial: String { self.name.map { String($0.prefix(1)).uppercased() } ?? "P" }
}
