import Foundation

/// The one letter a portrait shows when there is no photograph to show.
enum AvatarMonogram {
    /// The first letter or digit of a name, capitalised when that still leaves
    /// one letter: "ß" would become "SS", and a portrait holds one. Whatever
    /// stands in front of the name — "@anna", "🙂 Anna" — is passed over, and a
    /// name with nothing to read gives nothing, for the caller to draw a figure.
    static func letter(for name: String) -> String? {
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let capital = first.uppercased()
        return capital.count == 1 ? capital : String(first)
    }
}
