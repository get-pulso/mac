import Foundation

enum NativeError: LocalizedError {
    case message(String)

    // MARK: Internal

    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
