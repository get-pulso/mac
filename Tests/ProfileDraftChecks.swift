import Foundation

@main
struct ProfileDraftChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool) { precondition(condition); checks += 1 }
        let empty = ProfileDraft()
        expect(empty.errors.isEmpty)
        expect(empty.normalized == empty)
        var draft = ProfileDraft(firstName: " Serafim ", lastName: " Cloud ", location: " SF ", bio: "First paragraph.\n\nSecond paragraph.")
        expect(draft.normalized.firstName == "Serafim")
        expect(draft.normalized.lastName == "Cloud")
        expect(draft.normalized.location == "SF")
        expect(draft.normalized.bio.contains("\n\n"))
        expect(draft.errors.isEmpty)
        draft.bio = String(repeating: "x", count: ProfileDraft.bioLimit)
        expect(draft.errors[.bio] == nil)
        draft.bio += "x"
        expect(draft.errors[.bio] != nil)
        expect(draft.bio.count == ProfileDraft.bioLimit + 1)
        draft.bio = "👩🏽‍💻"
        expect(draft.bio.count == 1)
        draft.location = String(repeating: "x", count: ProfileDraft.locationLimit + 1)
        expect(draft.errors[.location] != nil)
        for value in ["example.com", "https://example.com/me", " http://example.com "] {
            expect(ProfileDraft.websiteURL(value) != nil)
        }
        for value in ["", "has spaces.com", "javascript:alert(1)", "file:///tmp/file", "https://", "https://user:password@example.com"] {
            expect(ProfileDraft.websiteURL(value) == nil)
        }
        expect(ProfileDraft.websiteURL("example.com")?.absoluteString == "https://example.com")
        for value in ["@serafim", "serafim", "https://x.com/serafim", "twitter.com/serafim", "https://www.x.com/serafim?ref=profile"] {
            expect(ProfileDraft.socialHandle(value, hosts: ["x.com", "twitter.com"]) == "serafim")
        }
        expect(ProfileDraft.socialHandle("https://t.me/serafim", hosts: ["t.me", "telegram.me"]) == "serafim")
        for value in ["@", "has spaces", "https://evil.example/serafim", "https://x.com/user/status/123", "https://x.com/"] {
            expect(ProfileDraft.socialHandle(value, hosts: ["x.com"]) == nil)
        }
        expect(ProfileDraft.socialHandle("  ", hosts: ["x.com"]) == "")
        let saved = ProfileDraft(website: "https://example.com", twitter: "serafim")
        let equivalent = ProfileDraft(website: "example.com", twitter: "@serafim")
        expect(saved.normalized == equivalent.normalized)
        var edited = saved
        edited.bio = "An unsaved draft."
        expect(saved.normalized != edited.normalized)
        for (raw, label) in [("firstlight.sh", "firstlight.sh"), ("https://www.21st.dev/", "21st.dev"),
                             ("https://github.com/serafimcloud/", "github.com/serafimcloud")] {
            expect(ProfileLink(.website, raw)?.label == label)
        }
        expect(ProfileLink(.website, "firstlight.sh")?.url.absoluteString == "https://firstlight.sh")
        for raw in ["serafimcloud", "@serafimcloud", "https://twitter.com/serafimcloud"] {
            expect(ProfileLink(.x, raw)?.label == "@serafimcloud")
            expect(ProfileLink(.x, raw)?.url.absoluteString == "https://x.com/serafimcloud")
        }
        expect(ProfileLink(.telegram, "t.me/serafim")?.url.absoluteString == "https://t.me/serafim")
        for (kind, raw) in [(ProfileLink.Kind.website, nil), (.website, ""), (.x, " "), (.x, "https://x.com/user/status/123"),
                            (.telegram, "https://evil.example/serafim")] {
            expect(ProfileLink(kind, raw) == nil)
        }
        expect(URL(string: "https://developer.apple.com/xcode/")?.displayAddress == "developer.apple.com/xcode")
        print("Profile draft checks passed: \(checks); multiline text, limits, normalization, invalid links, link labels and dirty comparison.")
    }
}
