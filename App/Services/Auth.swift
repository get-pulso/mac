import Alamofire
import Combine
import Foundation
import KeychainAccess

actor Auth {
    // MARK: Internal

    var invalidationPublisher: AnyPublisher<Void, Never> {
        self.invalidationSubject.eraseToAnyPublisher()
    }

    var hasToken: Bool {
        (try? self.keychain.get(Keys.refreshToken.rawValue)) != nil
    }

    func authToken() throws -> String? {
        try self.keychain.get(Keys.jwtToken.rawValue)
    }

    func refreshAccessToken() async throws {
        guard let refreshToken = try self.keychain.get(Keys.refreshToken.rawValue) else {
            return
        }

        var request = URLRequest(url: URL(string: "https://pulso.sh/api/user/refresh-token")!)
        request.method = .post
        request.headers = [
            .contentType("application/json"),
        ]
        request.httpBody = try JSONEncoder().encode([
            "refreshToken": refreshToken,
        ])

        let response = try await AF.request(request)
            .serializingDecodable(RefreshTokenResponse.self)
            .value

        try self.keychain.set(response.jwt, key: Keys.jwtToken.rawValue)
    }

    func update(jwtToken: String, refreshToken: String) throws {
        try self.keychain.set(jwtToken, key: Keys.jwtToken.rawValue)
        try self.keychain.set(refreshToken, key: Keys.refreshToken.rawValue)
    }

    func invalidateTokens() throws {
        try self.keychain.remove(Keys.jwtToken.rawValue)
        try self.keychain.remove(Keys.refreshToken.rawValue)
        self.invalidationSubject.send()
    }

    // MARK: Private

    private enum Keys: String {
        case jwtToken
        case refreshToken
    }

    private let keychain = Keychain(service: "com.get-pulso.mac.auth")
    private let invalidationSubject = PassthroughSubject<Void, Never>()
}
