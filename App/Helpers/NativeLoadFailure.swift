import Foundation

/// Why a list could not be loaded, as far as the popover should say. Being
/// offline is the one failure with a different remedy (wait, or get back
/// online), so it is the one the popover names; everything else is "try
/// again", with the error's own words kept as small print.
struct NativeLoadFailure: Equatable {
    // MARK: Lifecycle

    /// `online` is what the system's path monitor says at the moment of the
    /// failure. A request that failed for any reason while the Mac had no
    /// route out is an offline failure, whatever the error code.
    init(_ error: Error, online: Bool = true) {
        self.message = error.localizedDescription
        if !online { self.kind = .offline; return }
        let code = (error as? URLError)?.code ?? URLError.Code(rawValue: (error as NSError).code)
        let isURLError = error is URLError || (error as NSError).domain == NSURLErrorDomain
        self.kind = isURLError && Self.offlineCodes.contains(code) ? .offline : .failed
    }

    // MARK: Internal

    enum Kind: Equatable {
        /// No route to the server: the Mac is off the network.
        case offline
        /// The server was reached, or could not be, for some other reason.
        case failed
    }

    let kind: Kind
    /// What the error said, for the notice under a list that still has rows.
    let message: String

    var isOffline: Bool { self.kind == .offline }

    // MARK: Private

    /// Codes that mean the Mac has no way to the internet at all, not that
    /// one server is down. A timeout or a refused connection stays "failed":
    /// calling a slow server "offline" would send people to check their Wi-Fi.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed, .cannotFindHost,
        .internationalRoamingOff, .dataNotAllowed,
    ]
}
