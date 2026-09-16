import Foundation

struct ProfileDraft: Equatable {
    enum Field: String, CaseIterable { case firstName, lastName, username, location, bio, website, twitter, telegram }

    static let bioLimit = 280
    static let locationLimit = 120

    var firstName = ""
    var lastName = ""
    var username = ""
    var location = ""
    var bio = ""
    var website = ""
    var twitter = ""
    var telegram = ""

    var normalized: Self {
        var result = self
        result.firstName = self.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.lastName = self.lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = self.username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.location = self.location.trimmingCharacters(in: .whitespacesAndNewlines)
        result.bio = self.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        result.website = Self.websiteURL(self.website)?.absoluteString ?? self.website
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result.twitter = Self.socialHandle(self.twitter, hosts: ["x.com", "twitter.com"]) ?? self.twitter
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result.telegram = Self.socialHandle(self.telegram, hosts: ["t.me", "telegram.me"]) ?? self.telegram
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    var errors: [Field: String] {
        var errors: [Field: String] = [:]
        if self.bio.count > Self
            .bioLimit { errors[.bio] = "Use \(Self.bioLimit) characters or fewer. Your text hasn't been shortened." }
        if self.location.count > Self
            .locationLimit { errors[.location] = "Use \(Self.locationLimit) characters or fewer." }
        if !self.website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Self.websiteURL(self.website) == nil {
            errors[.website] = "Enter a website, like example.com or https://example.com."
        }
        if Self.socialHandle(self.twitter, hosts: ["x.com", "twitter.com"]) == nil {
            errors[.twitter] = "Enter a username or an X profile link."
        }
        if Self.socialHandle(self.telegram, hosts: ["t.me", "telegram.me"]) == nil {
            errors[.telegram] = "Enter a username or a Telegram profile link."
        }
        return errors
    }

    static func websiteURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        let input = URL(string: value)?.scheme == nil ? "https://" + value : value
        guard let url = URL(string: input), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func socialHandle(_ raw: String, hosts: Set<String>) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        if value.contains("/") || value.contains(":") {
            guard let url = websiteURL(value), let host = url.host?.lowercased(),
                  hosts.contains(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host),
                  url.pathComponents.count == 2 else { return nil }
            value = url.lastPathComponent
        }
        if value.hasPrefix("@") { value.removeFirst() }
        guard !value.isEmpty,
              value.utf8
              .allSatisfy({
                  (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 })
        else { return nil }
        return value
    }
}
