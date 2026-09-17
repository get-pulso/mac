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
        self.payload(raw)?["type"] as? String == "default"
    }

    /// Whether this is the picture Google had for the account, as Clerk copied
    /// it at sign-in. Google draws one of its own for an account with no
    /// photograph — a coloured square and a white letter — and hands it over
    /// like any photo, so a picture from here is the only kind worth looking
    /// into for one. An upload that happens to look like a letter stays a photo.
    static func isFromGoogle(_ raw: String?) -> Bool {
        if let raw, self.isGoogle(URL(string: raw)) { return true }
        guard
            let payload = self.payload(raw),
            payload["type"] as? String == "proxy",
            let source = (payload["src"] as? String).flatMap(URL.init(string:))
        else { return false }
        return self.isGoogle(source) || source.path.hasPrefix("/oauth_google/")
    }

    // MARK: Private

    private static let sizingKeys: Set<String> = ["width", "height", "fit", "quality"]

    private static func isClerk(_ raw: String) -> Bool {
        URL(string: raw)?.host?.hasSuffix("clerk.com") == true
    }

    private static func isGoogle(_ url: URL?) -> Bool {
        url?.host?.hasSuffix("googleusercontent.com") == true
    }

    /// What Clerk signed into the path of a picture it serves: base64url JSON
    /// naming what the picture is and where it came from.
    private static func payload(_ raw: String?) -> [String: Any]? {
        guard let raw, self.isClerk(raw) else { return nil }
        guard let token = raw
            .split(whereSeparator: { "/?&=".contains($0) })
            .first(where: { $0.hasPrefix("eyJ") })
        else { return nil }

        var encoded = String(token)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
