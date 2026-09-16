import Foundation

enum NativeError: LocalizedError {
    case message(String)
    case rateLimited(String, seconds: Int, daily: Bool)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case let .message(text),
             let .rateLimited(text, _, _): return text
        }
    }
}
