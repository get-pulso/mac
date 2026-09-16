import Foundation

@main
enum WelcomeAccountChecks {
    static func main() {
        let named = WelcomeAccount(
            id: "fixture",
            firstName: "  Sam  ",
            fullName: "Sam Example",
            username: "sam",
            avatarURL: "https://example.invalid/avatar.png"
        )
        precondition(named.name == "Sam")
        precondition(named.buttonTitle == "Continue as Sam")
        precondition(named.initial == "S")
        precondition(named.avatarURL != nil)
        let full = WelcomeAccount(
            id: "fixture",
            firstName: " \n ",
            fullName: "Sam Example",
            username: "sam",
            avatarURL: ""
        )
        precondition(full.name == "Sam Example" && full.avatarURL == nil)
        let handle = WelcomeAccount(id: "fixture", firstName: nil, fullName: nil, username: " sam ", avatarURL: nil)
        precondition(handle.name == "sam")
        let anonymous = WelcomeAccount(id: "fixture", firstName: nil, fullName: "", username: " ", avatarURL: nil)
        precondition(anonymous.name == nil)
        precondition(anonymous.buttonTitle == "Continue to Firstlight")
        precondition(anonymous.initial == "P")
        print("PASS: 9 welcome account checks; real names, trimming, fallback and avatar availability")
    }
}
