import Foundation

@main
struct NativeContracts {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool) { precondition(condition); checks += 1 }
        // Pin the API base URL before anything reads it, so the host allowed only
        // through AppEnvironment.baseURL stays distinct from the public domain.
        setenv("FIRSTLIGHT_BASE_URL", "http://localhost:3001", 1)
        expect(try InviteInput.parse(" abc-123 \n") == .friendCode("ABC-123"))
        expect(try InviteInput.parse("firstlight://join/abc123") == .friendCode("ABC123"))
        expect(try InviteInput.parse("https://firstlight.sh/join/abc123") == .friendCode("ABC123"))
        expect(try InviteInput.parse("firstlight://invite?token=test_token") == .token("test_token"))
        expect(try InviteInput.parse("https://firstlight.sh/invite?token=abc") == .token("abc"))
        expect(try InviteInput.parse("http://localhost:3001/invite?token=abc") == .token("abc"))
        // The arrival page appends its handoff nonce to whatever it hands over;
        // the invitation itself has to read the same either way.
        expect(
            try InviteInput
                .parse("firstlight://join/abc123?h=11111111-2222-3333-4444-555555555555") == .friendCode("ABC123")
        )
        expect(
            try InviteInput
                .parse("firstlight://invite?token=test_token&h=11111111-2222-3333-4444-555555555555") ==
                .token("test_token")
        )
        for input in ["", "   ", "https://evil.example/join/ABC", "javascript:alert(1)", "firstlight://invite", "has spaces", "file:///join/abc", "firstlight://join", "https://firstlight.sh/join/", "firstlight://callback?token=x"] {
            do { _ = try InviteInput.parse(input); preconditionFailure("Accepted invalid invite") }
            catch { checks += 1 }
        }
        // The landing page's link is the one clipboard invitation accepted
        // without a press, so only an explicit true may mark it.
        let landingInvite = try JSONDecoder().decode(
            NativeJoinInfo.self,
            from: Data(#"{"invite":{"code":"U8MUXZ62","inviterId":"a","inviterName":"Serafim","inviterAvatarUrl":null,"isDefaultInviter":true}}"#.utf8)
        )
        expect(landingInvite.invite.isDefaultInviter == true)
        let friendInvite = try JSONDecoder().decode(
            NativeJoinInfo.self,
            from: Data(#"{"invite":{"code":"ABC12345","inviterId":"b","inviterName":"Anna","inviterAvatarUrl":null,"isDefaultInviter":false}}"#.utf8)
        )
        expect(friendInvite.invite.isDefaultInviter == false)
        let olderServerInvite = try JSONDecoder().decode(
            NativeJoinInfo.self,
            from: Data(#"{"invite":{"code":"ABC12345","inviterName":"Anna"}}"#.utf8)
        )
        expect(olderServerInvite.invite.isDefaultInviter == nil && olderServerInvite.invite.inviterId == nil)
        // The profile's own words: nulls and missing keys read as nothing, and
        // a patch carries only the fields it sets, an empty string included.
        let about = try JSONDecoder().decode(
            NativeProfileAbout.self,
            from: Data(#"{"bio":"Building 21st.dev and Firstlight.","location":null,"twitter":"korablev"}"#.utf8)
        )
        expect(about == NativeProfileAbout(bio: "Building 21st.dev and Firstlight.", twitter: "korablev"))
        expect(String(decoding: try JSONEncoder().encode(NativeProfileAbout(twitter: "")), as: UTF8.self) == #"{"twitter":""}"#)
        expect(String(decoding: try JSONEncoder().encode(NativeProfileAbout()), as: UTF8.self) == "{}")
        let person = try JSONDecoder().decode(NativePerson.self, from: Data(#"{"user_id":"test","name":null,"active_minutes":125.5}"#.utf8))
        expect(person.displayName == "Firstlight user")
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
            from: Data(#"{"active_minutes":12,"period":"24h","last_active":"2026-09-15T20:00:00Z","active_app":{"bundle_identifier":"com.apple.Safari","name":"Safari","active_minutes":8.5,"last_active_at":"2026-09-15T20:00:00Z","icon_url":"https://firstlight.sh/api/apps/icon/com.apple.Safari"},"top_apps":[]}"#.utf8)
        )
        expect(appActivity.active_app?.name == "Safari" && appActivity.active_app?.active_minutes == 8.5)
        expect(ContentLoadPhase.resolve(isLoading: true, hasContent: false, hasError: false) == .initial)
        expect(ContentLoadPhase.resolve(isLoading: true, hasContent: true, hasError: false) == .refreshing)
        expect(ContentLoadPhase.resolve(isLoading: false, hasContent: true, hasError: false) == .content)
        expect(ContentLoadPhase.resolve(isLoading: false, hasContent: false, hasError: false) == .empty)
        expect(ContentLoadPhase.resolve(isLoading: false, hasContent: false, hasError: true) == .failedEmpty)
        expect(ContentLoadPhase.resolve(isLoading: false, hasContent: true, hasError: true) == .failedWithContent)

        // Only a Mac with no route out is "offline"; a slow or refused server is
        // an ordinary failure, or people would be sent to check their Wi-Fi.
        expect(NativeLoadFailure(URLError(.notConnectedToInternet)).isOffline)
        expect(NativeLoadFailure(URLError(.networkConnectionLost)).isOffline)
        expect(NativeLoadFailure(URLError(.dnsLookupFailed)).isOffline)
        expect(NativeLoadFailure(NSError(domain: NSURLErrorDomain, code: URLError.cannotFindHost.rawValue)).isOffline)
        expect(!NativeLoadFailure(URLError(.timedOut)).isOffline)
        expect(!NativeLoadFailure(URLError(.cannotConnectToHost)).isOffline)
        expect(!NativeLoadFailure(NativeError.message("Server said no")).isOffline)
        expect(NativeLoadFailure(NativeError.message("Server said no")).message == "Server said no")
        // The path monitor's word outranks the error code at the moment of failure.
        expect(NativeLoadFailure(NativeError.message("Server said no"), online: false).isOffline)
        expect(NativeLoadFailure(URLError(.notConnectedToInternet), online: true).isOffline)
        let requests = try JSONDecoder().decode(NativeRequests.self, from: Data(#"{"incoming":[],"outgoing":[]}"#.utf8))
        expect(requests.incoming.isEmpty && requests.outgoing.isEmpty)
        let personalInvite = try JSONDecoder().decode(
            NativePersonalInvite.self,
            from: Data(#"{"personalInviteCode":"ABC123","personalInviteLink":"https://firstlight.sh/join/ABC123"}"#.utf8)
        )
        expect(personalInvite.personalInviteCode == "ABC123")
        let user = try JSONDecoder().decode(UserResponse.self, from: Data(#"{"user":{"id":"id","name":null},"groups":[]}"#.utf8))
        expect(user.user.name == nil)
        let members = try JSONDecoder().decode(NativeMembers.self, from: Data(#"{"group":{"id":"g","name":"Builders","is_user_creator":true},"members":[{"id":"u","name":null,"is_creator":true}]}"#.utf8))
        expect(members.group.is_user_creator && members.members[0].displayName == "Firstlight user")
        let page = try JSONDecoder().decode(
            NativeLeaderboardPage.self,
            from: Data(#"{"items":[{"user_id":"a","name":"A","active_minutes":10}],"total":120,"next_offset":50,"me":{"user_id":"me","name":"Me","rank":77,"active_minutes":1}}"#.utf8)
        )
        expect(page.items.count == 1 && page.total == 120 && page.next_offset == 50 && page.me?.rank == 77)
        let lastPage = try JSONDecoder().decode(NativeLeaderboardPage.self, from: Data(#"{"items":[],"total":1,"next_offset":null,"me":null}"#.utf8))
        expect(lastPage.items.isEmpty && lastPage.next_offset == nil && lastPage.me == nil)
        let justNow = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40))
        let fractionalNow = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40)).replacingOccurrences(of: "Z", with: ".250Z")
        for stamp in [justNow, fractionalNow] {
            let recent = try JSONDecoder().decode(NativePerson.self, from: Data("{\"user_id\":\"r\",\"last_active_at\":\"\(stamp)\"}".utf8))
            expect(recent.isActiveNow)
        }
        let stale = try JSONDecoder().decode(NativePerson.self, from: Data(#"{"user_id":"s","last_active_at":"2000-01-01T00:00:00Z"}"#.utf8))
        expect(!stale.isActiveNow && !person.isActiveNow)
        print("Native contract checks passed: \(checks)")
    }
}
