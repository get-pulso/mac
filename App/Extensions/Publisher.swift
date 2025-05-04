import Combine

extension Publisher {
    func ignoreError() -> Publishers.Catch<Self, Empty<Self.Output, Never>> {
        self.catch { _ in Empty<Self.Output, Never>() }
    }
}
