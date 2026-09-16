import Foundation

enum ContentLoadPhase: Equatable {
    case initial
    case refreshing
    case content
    case empty
    case failedEmpty
    case failedWithContent

    // MARK: Internal

    static func resolve(isLoading: Bool, hasContent: Bool, hasError: Bool) -> Self {
        if isLoading { return hasContent ? .refreshing : .initial }
        if hasError { return hasContent ? .failedWithContent : .failedEmpty }
        return hasContent ? .content : .empty
    }
}
