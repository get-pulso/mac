import Foundation

/// The portrait asked for at the size it is about to be shown at. Every avatar
/// comes through Clerk's image CDN, which takes the size in the query, so a row
/// can ask for a thumbnail and the photo screen for something worth looking at.
/// Anything served from elsewhere is passed through untouched.
enum ProfilePhotoURL {
    // MARK: Internal

    /// The same picture, rendered wide enough to fill a screen. `height` and
    /// `fit` are dropped along with the old width: a row wants a square crop of
    /// a face, and the photo screen wants the photograph that was uploaded.
    static func sized(_ raw: String?, width: Int) -> URL? {
        guard let raw, let url = URL(string: raw) else { return nil }
        guard
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            self.isClerk(raw)
        else { return url }

        var items = (components.queryItems ?? []).filter { !Self.sizingKeys.contains($0.name) }
        items.append(URLQueryItem(name: "width", value: String(width)))
        items.append(URLQueryItem(name: "quality", value: "90"))
        components.queryItems = items
        return components.url ?? url
    }

    /// Whether Clerk drew this one itself. An account with no photograph gets a
    /// generated tile, and a generated tile has nothing inside it worth a
    /// screen — so the portrait is not offered as something to open. The marker
    /// is in the payload Clerk signs into the path, the way the web reads it.
    static func isPlaceholder(_ raw: String?) -> Bool {
        guard let raw, self.isClerk(raw) else { return false }
        guard let token = raw
            .split(whereSeparator: { "/?&=".contains($0) })
            .first(where: { $0.hasPrefix("eyJ") })
        else { return false }

        var encoded = String(token)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard
            let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
            let payload = String(data: data, encoding: .utf8)
        else { return false }

        return payload.filter { !$0.isWhitespace }.contains("\"type\":\"default\"")
    }

    // MARK: Private

    private static let sizingKeys: Set<String> = ["width", "height", "fit", "quality"]

    private static func isClerk(_ raw: String) -> Bool {
        URL(string: raw)?.host?.hasSuffix("clerk.com") == true
    }
}
