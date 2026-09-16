import Alamofire
import Defaults
import Foundation

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
                app: app
            ),
            expectedUserID: userID
        )
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
        let baseURL = baseURL ?? Self.baseURL
        let sessionID = await NativeSession.shared.session?.id
        if let expectedUserID, Defaults[.currentUserID] != expectedUserID { throw CancellationError() }

        let url: URL
        if let query {
            var components = URLComponents(
                url: baseURL.appending(path: path),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = query.map(URLQueryItem.init)
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
        if auth, await NativeSession.shared.session?.id != sessionID { throw CancellationError() }

        let task = AF.request(request).serializingData()

        let response = await task.response
        try Task.checkCancellation()
        if auth, await NativeSession.shared.session?.id != sessionID { throw CancellationError() }

        if auth, response.response?.statusCode == 401 {
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

        let data = try await task.value
        guard let status = response.response?.statusCode, (200 ..< 300).contains(status) else {
            let message = (try? self.jsonDecoder.decode(APIError.self, from: data))?.error
            throw NativeError.message(message ?? "The server could not complete this request.")
        }
        return try self.jsonDecoder.decode(Response.self, from: data)
    }

    // MARK: Private

    private struct APIError: Decodable { let error: String? }

    private static let baseURL = AppEnvironment.baseURL

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
}
