import Foundation

@main
struct NativeContracts {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool) { precondition(condition); checks += 1 }
        expect(try InviteInput.parse(" abc-123 \n") == .friendCode("ABC-123"))
        expect(try InviteInput.parse("pulso://join/abc123") == .friendCode("ABC123"))
        expect(try InviteInput.parse("https://pulso.sh/join/abc123") == .friendCode("ABC123"))
        expect(try InviteInput.parse("pulso://invite?token=test_token") == .token("test_token"))
        expect(try InviteInput.parse("https://pulso.sh/invite?token=abc") == .token("abc"))
        expect(try InviteInput.parse("https://pulso-wheat-six.vercel.app/invite?token=abc") == .token("abc"))
        for input in ["", "   ", "https://evil.example/join/ABC", "javascript:alert(1)", "pulso://invite", "has spaces", "file:///join/abc", "pulso://join", "https://pulso.sh/join/", "pulso://callback?token=x"] {
            do { _ = try InviteInput.parse(input); preconditionFailure("Accepted invalid invite") }
            catch { checks += 1 }
        }
        let person = try JSONDecoder().decode(NativePerson.self, from: Data(#"{"user_id":"test","name":null,"active_minutes":125.5}"#.utf8))
        expect(person.displayName == "Pulso user")
        let activePerson = try JSONDecoder().decode(
            NativePerson.self,
            from: Data(#"{"user_id":"test","name":"Sam","active_minutes":4,"last_active_at":"2026-09-15T20:00:00Z","active_app":{"bundle_identifier":"com.apple.Safari","name":"Safari","last_active_at":"2026-09-15T20:00:00Z","icon_url":null}}"#.utf8)
        )
        expect(activePerson.active_app?.name == "Safari")
        expect(person.timeLabel == "2h 5m")
        expect(DurationLabel.minutes(0) == "0m")
        expect(DurationLabel.minutes(59.9) == "59m")
        expect(DurationLabel.minutes(60) == "1h")
        expect(DurationLabel.minutes(61) == "1h 1m")
        expect(DurationLabel.minutes(-5) == "0m")
        expect(DurationLabel.minutes(.nan) == "0m")
        expect(DurationLabel.minutes(.infinity) == "0m")
        let activity = try JSONDecoder().decode(NativeActivity.self, from: Data(#"{"active_minutes":0,"period":"24h","last_active":null}"#.utf8))
        expect(activity.active_minutes == 0 && activity.intervals == nil && activity.active_app == nil)
        let appActivity = try JSONDecoder().decode(
            NativeActivity.self,
            from: Data(#"{"active_minutes":12,"period":"24h","last_active":"2026-09-15T20:00:00Z","active_app":{"bundle_identifier":"com.apple.Safari","name":"Safari","active_minutes":8.5,"last_active_at":"2026-09-15T20:00:00Z","icon_url":"https://pulso.sh/api/apps/icon/com.apple.Safari"},"top_apps":[]}"#.utf8)
        )
        expect(appActivity.active_app?.name == "Safari" && appActivity.active_app?.active_minutes == 8.5)
        expect(ContentLoadPhase.resolve(isLoading: true, hasContent: false, hasError: false) == .initial)
        expect(ContentLoadPhase.resolve(isLoading: true, hasContent: true, hasError: false) == .refreshing)
        expect(ContentLoadPhase.resolve(isLoading: false, hasContent: true, hasError: false) == .content)
        expect(ContentLoadPhase.resolve(isLoading: false, hasContent: false, hasError: false) == .empty)
        expect(ContentLoadPhase.resolve(isLoading: false, hasContent: false, hasError: true) == .failedEmpty)
        expect(ContentLoadPhase.resolve(isLoading: false, hasContent: true, hasError: true) == .failedWithContent)
        let requests = try JSONDecoder().decode(NativeRequests.self, from: Data(#"{"incoming":[],"outgoing":[]}"#.utf8))
        expect(requests.incoming.isEmpty && requests.outgoing.isEmpty)
        let history = try JSONDecoder().decode(NativeInviteHistory.self, from: Data(#"{"recentInvites":[{"id":"i","token":"t","groups":null,"used":false}]}"#.utf8))
        expect(history.recentInvites.count == 1)
        let user = try JSONDecoder().decode(UserResponse.self, from: Data(#"{"user":{"id":"id","name":null},"groups":[]}"#.utf8))
        expect(user.user.name == nil)
        let tokens = try JSONDecoder().decode(NativeTokens.self, from: Data(#"{"tokens":{"current":0,"totalEarned":2,"maxBalance":10,"canGetRescueToken":true,"nextRescueTokenIn":null},"transactions":[{"id":"i","amount":-1,"reason":"invite_accepted","created_at":null}],"pendingActivations":[{"id":"p","users":null}]}"#.utf8))
        expect(tokens.tokens.canGetRescueToken)
        expect(tokens.transactions[0].amount == -1)
        expect(tokens.pendingActivations[0].users == nil)
        let members = try JSONDecoder().decode(NativeMembers.self, from: Data(#"{"group":{"id":"g","name":"Builders","is_user_creator":true},"members":[{"id":"u","name":null,"is_creator":true}]}"#.utf8))
        expect(members.group.is_user_creator && members.members[0].displayName == "Pulso user")
        print("Native contract checks passed: \(checks)")
    }
}
