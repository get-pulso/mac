import Foundation

enum AppEnvironment {
    static let isLocalBackend = ["localhost", "127.0.0.1"].contains(baseURL.host)

    static let baseURL: URL = {
        if let value = ProcessInfo.processInfo.environment["PULSO_BASE_URL"],
           let url = URL(string: value)
        {
            return url
        }

        if let value = Bundle.main.object(forInfoDictionaryKey: "PulsoAPIBaseURL") as? String,
           let url = URL(string: value), let scheme = url.scheme, ["https", "http"].contains(scheme) { return url }
        return URL(string: "https://pulso-wheat-six.vercel.app")!
    }()
}
