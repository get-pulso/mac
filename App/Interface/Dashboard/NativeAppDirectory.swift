import Combine
import Defaults
import Dependencies
import Foundation

struct NativeAppCard: Decodable, Identifiable {
    // MARK: Lifecycle

    init(activity: NativeAppActivity) {
        self.bundle_identifier = activity.bundle_identifier
        self.name = activity.name
        self.icon_url = activity.icon_url
    }

    // MARK: Internal

    let bundle_identifier: String
    let name: String
    let icon_url: String?
    var category: String? = nil
    var description: String? = nil
    var website_url: String? = nil
    var rank: Int? = nil
    var user_count: Int? = nil

    var id: String { self.bundle_identifier }
}

struct NativeAppTopPage: Decodable {
    var items: [NativeAppCard]
    let total: Int
    let next_cursor: String?
    let snapshot: String
}

struct NativeAppPeoplePage: Decodable {
    let app: NativeAppCard
    var items: [NativePerson]
    let total: Int
    let next_cursor: String?
    let snapshot: String
    let me: NativePerson?
    let my_minutes: Double
    let source: NativePerson?
}

@MainActor
final class NativeAppDirectory: ObservableObject {
    // MARK: Internal

    @Published private(set) var contexts = NativeAppRankingContexts()
    @Published var cards: [String: NativeAppCard] = [:]
    @Published var topPages: [String: NativeAppTopPage] = [:]
    @Published var peoplePages: [String: NativeAppPeoplePage] = [:]
    @Published var loading = Set<String>()
    @Published var errors: [String: String] = [:]
    @Published var expanded = Set<String>()

    func context(for bundle: String?) -> NativeAppRankingContext {
        self.contexts.context(for: bundle)
    }

    func setScope(_ scope: String, for bundle: String?) {
        self.contexts.setScope(scope, for: bundle)
    }

    func key(_ bundle: String?, period: String) -> String {
        let context = self.context(for: bundle)
        return "\(self.revision)|\(Defaults[.currentUserID] ?? "")|\(context.scope)|\(period)|\(bundle ?? "top")|\(context.sourceID ?? "")"
    }

    func remember(_ app: NativeAppCard, from person: NativePerson?, scope: String, returning: Bool) {
        if self.cards[app.id]?.description == nil { self.cards[app.id] = app }
        self.contexts.open(app.id, scope: scope, sourceID: person?.id, returning: returning)
    }

    func clear() {
        self.revision += 1
        self.requests.removeAll()
        self.peoplePages.removeAll()
        self.topPages.removeAll()
        self.loading.removeAll()
        self.errors.removeAll()
        self.loadedAt.removeAll()
        self.expanded.removeAll()
    }

    func load(_ bundle: String?, period: String, more: Bool = false, force: Bool = false) async {
        let context = self.context(for: bundle)
        let key = self.key(bundle, period: period)
        // A quick Back restores the complete paginated list, not just page one.
        if !more, !force, let loaded = self.loadedAt[key], Date().timeIntervalSince(loaded) < 30 { return }
        if more, self.loading.contains(key) { return }
        let cursor = bundle == nil ? self.topPages[key]?.next_cursor : self.peoplePages[key]?.next_cursor
        if more, cursor == nil { return }
        let token = UUID()
        self.requests[key] = token
        self.loading.insert(key)
        self.errors[key] = nil
        defer {
            if self.requests[key] == token {
                self.requests[key] = nil
                self.loading.remove(key)
            }
        }
        let query: [String: String?] = [
            "period": period, "scope": context.scope, "limit": "30", "cursor": more ? cursor : nil,
            "source_user_id": context.sourceID,
        ]
        do {
            if let bundle {
                var page: NativeAppPeoplePage = try await self.network.request(
                    path: "/api/apps/\(bundle)", method: .get, query: query
                )
                guard !Task.isCancelled, self.requests[key] == token else { return }
                if more, let previous = self.peoplePages[key] {
                    let existing = Set(previous.items.map(\.id))
                    page.items = previous.items + page.items.filter { !existing.contains($0.id) }
                }
                self.cards[bundle] = page.app
                self.peoplePages[key] = page
                SocialStore.warmPortraits(of: page.items)
            } else {
                var page: NativeAppTopPage = try await self.network.request(
                    path: "/api/apps/leaderboard", method: .get, query: query
                )
                guard !Task.isCancelled, self.requests[key] == token else { return }
                if more, let previous = self.topPages[key] {
                    let existing = Set(previous.items.map(\.id))
                    page.items = previous.items + page.items.filter { !existing.contains($0.id) }
                }
                for app in page.items { self.cards[app.id] = app }
                self.topPages[key] = page
            }
            if !more { self.loadedAt[key] = Date() }
        } catch {
            guard !Task.isCancelled, self.requests[key] == token else { return }
            self.errors[key] = "Couldn't load \(bundle == nil ? "apps" : "people"). Try again."
        }
    }

    // MARK: Private

    @Dependency(\.network) private var network
    @Published private var revision = 0
    private var requests: [String: UUID] = [:]
    private var loadedAt: [String: Date] = [:]
}
