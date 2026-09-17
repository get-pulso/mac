import Foundation

extension SocialStore {
    /// What the popover knows about requests and friends is stale the moment
    /// an event about them arrives: the Invite badge, the incoming tray, the
    /// list a new friend belongs in. Brought up to date whether or not the
    /// popover is open, so it opens on the truth.
    func friendEventsArrived(_ events: [NativeFriendEvent]) {
        let newFriends = events.filter { $0.knownKind == .accepted || $0.knownKind == .joined }
        for event in newFriends {
            self.recordDirectFriend(event.from.id)
        }
        let requests = events.contains { $0.knownKind == .request }
        Task {
            if requests { try? await self.loadRequests() }
            if !newFriends.isEmpty { await self.refresh(force: true) }
        }
    }

    /// Accepts a request from the notch. `respond` belongs to the popover and
    /// reports through its busy state and error line; nothing is watching
    /// those here, so the caller hears how it went instead.
    func acceptFromNotch(requestID: String, requesterID: String) async throws {
        try await self.mutate("/api/friends/requests/\(requestID)", body: ["action": "accept"])
        self.recordDirectFriend(requesterID)
        try? await self.loadRequests()
        await self.refresh(force: true)
    }

    /// Where a friend event leads, from the notch or from Notification Centre.
    /// A request goes to the requests, where it is answered; a new friend to
    /// their profile, which is open to you now.
    func openFriendEvent(_ kind: NativeFriendEvent.Kind, personID: String, name: String?, avatarURL: String?) {
        self.showList()
        switch kind {
        case .request:
            self.openTray(.incoming)
        case .accepted,
             .joined:
            if let person = self.people.first(where: { $0.id == personID })
                ?? Self.newcomer(id: personID, name: name, avatarURL: avatarURL)
            {
                self.openPerson(person)
            } else {
                self.openFriend(personID)
            }
        }
    }

    /// Someone the list has not loaded yet, drawn from what the event said
    /// about them. The profile asks for the rest by id, as it does for anyone.
    /// Decoded rather than built, so it does not follow every field the
    /// person model gains.
    private static func newcomer(id: String, name: String?, avatarURL: String?) -> NativePerson? {
        struct Seed: Encodable {
            let user_id: String
            let name: String?
            let avatar_url: String?
        }

        guard let data = try? JSONEncoder().encode(Seed(user_id: id, name: name, avatar_url: avatarURL))
        else { return nil }
        return try? JSONDecoder().decode(NativePerson.self, from: data)
    }
}
