import AppKit

/// The icon of an app that is installed on this Mac, asked for by bundle id.
///
/// A tracked app's icon normally comes from the server, uploaded by whichever
/// Mac ran the app first. Until that upload lands — and for mock people, whose
/// apps were never anywhere — the row has nothing to draw. But if the app is
/// sitting in this Mac's own Applications folder, its real icon is right here
/// for the asking, and Cursor looks like Cursor instead of a grey placeholder.
///
/// Launch Services is asked once per bundle id and the answer is kept, misses
/// included, so a list that redraws every minute does not go back to disk.
@MainActor
enum LocalAppIcons {
    // MARK: Internal

    static func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let cached = self.cache[bundleIdentifier] { return cached }
        let icon = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        self.cache[bundleIdentifier] = icon
        return icon
    }

    // MARK: Private

    /// A stored `nil` means Launch Services has already been asked and this Mac
    /// does not have the app, so the miss is not paid for twice.
    private static var cache: [String: NSImage?] = [:]
}
