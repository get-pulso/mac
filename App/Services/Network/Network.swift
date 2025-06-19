import Alamofire
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

    func publishActivity(start: Date, end: Date) async throws -> UpdateResponse {
        try await self.request(
            path: "/api/user/activity",
            method: .post,
            body: [
                "startTime": start,
                "endTime": end,
            ]
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

    // MARK: Private

    private static let baseURL = URL(string: "https://pulso.sh")!

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

    private func request<Response: Decodable>(
        baseURL: URL? = nil,
        path: String,
        method: HTTPMethod,
        auth: Bool = true,
        query: [String: String?]? = nil,
        body: Encodable? = nil,
        retryCounter: Int = 0
    ) async throws -> Response {
        let baseURL = baseURL ?? Self.baseURL

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

        var headers: HTTPHeaders = []

        if auth {
            guard let token = try await self.auth.authToken() else {
                throw URLError(.userAuthenticationRequired)
            }
            headers.add(.authorization(bearerToken: token))
        }

        if let body {
            request.httpBody = try self.jsonEncoder.encode(body)
            headers.add(.contentType("application/json"))
        }

        request.headers = headers

        let task = AF.request(request).serializingData()

        let response = await task.response

        if response.response?.statusCode == 401 {
            guard retryCounter == 0 else {
                try? await self.auth.invalidateTokens()
                throw URLError(.userAuthenticationRequired)
            }

            do {
                try await self.auth.refreshAccessToken()
            } catch {
                try? await self.auth.invalidateTokens()
                throw URLError(.userAuthenticationRequired)
            }

            return try await self.request(
                baseURL: baseURL,
                path: path,
                method: method,
                auth: auth,
                query: query,
                body: body,
                retryCounter: retryCounter + 1
            )
        }

        let data = try await task.value
        return try self.jsonDecoder.decode(Response.self, from: data)
    }
}
