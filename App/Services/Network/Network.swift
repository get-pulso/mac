import Alamofire
import Defaults
import Foundation

private struct NetworkTransportResponse: Sendable {
    let statusCode: Int?
    let data: Data
}

struct Network {
    // MARK: Lifecycle

    init(auth: Auth) {
        self.auth = auth
    }

    // MARK: Internal

    func verify(loginToken: String) async throws -> VerifyResponse {
        try await self.request(
            path: "/api/user/verify-token",
            method: .post,
            auth: false,
            body: [
                "token": loginToken,
            ]
        )
    }

    func userInfo() async throws -> UserResponse {
        try await self.request(
            path: "/api/user/me",
            method: .get
        )
    }

    func userActivity() async throws -> ActivityResponse {
        try await self.request(
            path: "/api/user/activity",
            method: .get
        )
    }

    /// Brings the stored name and photo in step with Clerk.
    func syncNativeProfile() async throws {
        let _: NativeAck = try await self.request(path: "/api/native/profile", method: .post)
    }

    /// What the signed-in person wrote about themselves.
    func profileAbout() async throws -> NativeProfileAbout {
        try await self.request(path: "/api/user/profile", method: .get)
    }

    /// Stores the fields set in `changes` and answers with the whole of it.
    func saveProfileAbout(_ changes: NativeProfileAbout) async throws -> NativeProfileAbout {
        try await self.request(path: "/api/user/profile", method: .patch, body: changes)
    }

    func publishActivity(_ activity: PendingActivity, userID: String) async throws -> UpdateResponse {
        struct TrackedApp: Encodable {
            let bundleIdentifier: String
            let name: String
            let version: String?
            let iconPNGBase64: String?
        }
        struct Payload: Encodable {
            let startTime: Date
            let endTime: Date
            let clientIntervalId: String
            let app: TrackedApp?
            /// Where this Mac thinks it is. A person's days are cut in their
            /// own zone, so it rides along with the activity that fills them
            /// and follows them when they move.
            let timeZone: String
        }
        let app: TrackedApp? = if let bundleIdentifier = activity.appBundleIdentifier,
                                  let name = activity.appName
        {
            TrackedApp(
                bundleIdentifier: bundleIdentifier,
                name: name,
                version: activity.appVersion,
                iconPNGBase64: activity.appIconPNGBase64
            )
        } else {
            nil
        }
        return try await self.request(
            path: "/api/user/activity",
            method: .post,
            body: Payload(
                startTime: activity.startedAt,
                endTime: activity.endedAt,
                clientIntervalId: activity.id,
                app: app,
                timeZone: TimeZone.current.identifier
            ),
            expectedUserID: userID
        )
    }

    /// Bumps waiting for this Mac, with the phrases it may send back. Reading
    /// the inbox marks nothing: the banners are acknowledged once they are on
    /// screen, so a crash in between leaves the bump to arrive next time.
    func bumpInbox() async throws -> NativeBumpInbox {
        try await self.request(path: "/api/bumps", method: .get)
    }

    /// Says what from one inbox read is safely shown: its bumps, and the
    /// friend events that came with them. A server that predates friend
    /// events ignores the second list.
    func acknowledgeBumps(_ ids: [String], friendEvents: [String] = []) async throws {
        struct Payload: Encodable { let ids: [String]; let friendEventIds: [String] }
        let _: NativeAck = try await self.request(
            path: "/api/bumps/ack",
            method: .post,
            body: Payload(ids: ids, friendEventIds: friendEvents)
        )
    }

    func sendBump(to friendID: String, kind: String) async throws -> NativeBumpSent {
        struct Payload: Encodable { let kind: String }
        return try await self.request(
            path: "/api/friends/\(friendID)/bump",
            method: .post,
            body: Payload(kind: kind)
        )
    }

    func bumpState(for personID: String) async throws -> NativeBumpState {
        try await self.request(path: "/api/friends/\(personID)/bump", method: .get)
    }

    func leaderboard(filter: TimeFilter) async throws -> [FriendResponse] {
        try await self.request(
            path: "/api/friends/leaderboard",
            method: .get,
            query: ["period": filter.rawValue]
        )
    }

    func leaderboard(groupId: String, filter: TimeFilter) async throws -> [FriendResponse] {
        try await self.request(
            path: "/api/friends/leaderboard",
            method: .get,
            query: ["group_id": groupId, "period": filter.rawValue]
        )
    }

    func request<Response: Decodable>(
        baseURL: URL? = nil,
        path: String,
        method: HTTPMethod,
        auth: Bool = true,
        query: [String: String?]? = nil,
        body: Encodable? = nil,
        retryCounter: Int = 0,
        expectedUserID: String? = nil
    ) async throws -> Response {
        try Task.checkCancellation()
        #if DEBUG
        // Developer mode for the invite flow answers its own endpoints, so the
        // trays can be walked through without a server or a second account.
        // Off by default; everything else still goes out as usual.
        if let mocked = try await InviteMocks.response(path: path, method: method.rawValue, query: query, body: body) {
            try Task.checkCancellation()
            guard (200 ..< 300).contains(mocked.status) else {
                let message = (try? self.jsonDecoder.decode(APIError.self, from: mocked.data))?.error
                throw NativeError.message(message ?? "The server could not complete this request.")
            }
            return try self.jsonDecoder.decode(Response.self, from: mocked.data)
        }
        #endif
        let baseURL = baseURL ?? Self.baseURL
        let sessionID = await NativeSession.shared.session?.id
        if let expectedUserID, Defaults[.currentUserID] != expectedUserID { throw CancellationError() }

        let url: URL
        if let query {
            var components = URLComponents(
                url: baseURL.appending(path: path),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
            guard let genURL = components?.url else {
                throw URLError(.badURL)
            }
            url = genURL
        } else {
            url = baseURL.appending(path: path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = 20
        // Screen models own freshness and invalidation. Avoid a second, opaque
        // URLCache policy returning data with a different lifetime.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        var headers: HTTPHeaders = []

        if auth {
            guard let token = try await self.auth.authToken() else {
                throw URLError(.userAuthenticationRequired)
            }
            headers.add(.authorization(bearerToken: token))
        }
        if let expectedUserID, Defaults[.currentUserID] != expectedUserID { throw CancellationError() }

        if let body {
            request.httpBody = try self.jsonEncoder.encode(body)
            headers.add(.contentType("application/json"))
        }

        request.headers = headers
        let preparedRequest = request
        if auth, await NativeSession.shared.session?.id != sessionID { throw CancellationError() }
        let requestScope = "\(auth ? "authenticated" : "public")|\(sessionID ?? "anonymous")"

        let response: NetworkTransportResponse
        if method == .get {
            let epoch = await Self.requestEpochs.value(for: requestScope)
            let key = "\(requestScope)|\(epoch)|\(url.absoluteString)"
            response = try await Self.getCoalescer.value(for: key) {
                try await Self.perform(preparedRequest)
            }
        } else {
            response = try await Self.perform(preparedRequest)
        }
        try Task.checkCancellation()
        if auth, await NativeSession.shared.session?.id != sessionID { throw CancellationError() }

        if auth, response.statusCode == 401 {
            guard retryCounter == 0 else {
                await NativeSession.shared.clearAccount()
                throw URLError(.userAuthenticationRequired)
            }

            do {
                try await self.auth.refreshAccessToken()
            } catch {
                throw URLError(.userAuthenticationRequired)
            }

            return try await self.request(
                baseURL: baseURL,
                path: path,
                method: method,
                auth: auth,
                query: query,
                body: body,
                retryCounter: retryCounter + 1,
                expectedUserID: expectedUserID
            )
        }

        guard let status = response.statusCode, (200 ..< 300).contains(status) else {
            let detail = try? self.jsonDecoder.decode(APIError.self, from: response.data)
            let message = detail?.error
            if response.statusCode == 429, let seconds = detail?.retry_after_seconds {
                throw NativeError.rateLimited(
                    message ?? "Try again later.",
                    seconds: seconds,
                    daily: detail?.reason == "daily_limit"
                )
            }
            throw NativeError.message(message ?? "The server could not complete this request.")
        }
        if method != .get { await Self.requestEpochs.advance(for: requestScope) }
        return try self.jsonDecoder.decode(Response.self, from: response.data)
    }

    // MARK: Private

    private struct APIError: Decodable {
        let error: String?
        let retry_after_seconds: Int?
        let reason: String?
    }

    private static let baseURL = AppEnvironment.baseURL
    private static let getCoalescer = NativeRequestCoalescer<String, NetworkTransportResponse>()
    private static let requestEpochs = NativeRequestEpochs<String>()

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let jsonDecoder: JSONDecoder = {
        let encoder = JSONDecoder()
        encoder.dateDecodingStrategy = .iso8601
        return encoder
    }()

    private let auth: Auth

    private static func perform(_ request: URLRequest) async throws -> NetworkTransportResponse {
        let response = await AF.request(request).serializingData().response
        return try NetworkTransportResponse(
            statusCode: response.response?.statusCode,
            data: response.result.get()
        )
    }
}
