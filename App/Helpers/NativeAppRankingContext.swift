/// Each ranking keeps its own audience and entry profile while another screen
/// is on top of it. Returning to that ranking restores the same request key.
struct NativeAppRankingContext: Equatable {
    var scope = "friends"
    var sourceID: String?
}

struct NativeAppRankingContexts {
    // MARK: Internal

    private(set) var top = NativeAppRankingContext()

    func context(for bundle: String?) -> NativeAppRankingContext {
        guard let bundle else { return self.top }
        return self.apps[bundle] ?? self.top
    }

    mutating func open(_ bundle: String, scope: String, sourceID: String?, returning: Bool) {
        if returning, self.apps[bundle] != nil { return }
        self.apps[bundle] = NativeAppRankingContext(scope: scope, sourceID: sourceID)
    }

    mutating func setScope(_ scope: String, for bundle: String?) {
        if let bundle {
            var context = context(for: bundle)
            context.scope = scope
            self.apps[bundle] = context
        } else {
            self.top.scope = scope
        }
    }

    // MARK: Private

    private var apps: [String: NativeAppRankingContext] = [:]
}
