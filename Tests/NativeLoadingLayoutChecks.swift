import AppKit
import SwiftUI

/// Offscreen geometry checks for every shared loading primitive. No window is
/// shown and no network, account, pasteboard, or application action is used.
@main
struct NativeLoadingLayoutChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func expect(_ condition: Bool) { precondition(condition); checks += 1 }

        let people = NSHostingController(rootView: NativePeopleSkeleton(rows: 5).frame(width: 350))
        let peopleSize = people.sizeThatFits(in: NSSize(width: 350, height: 500))
        expect(peopleSize.width == 350)
        expect(peopleSize.height >= 300 && peopleSize.height <= 380)

        let rows = NSHostingController(rootView: NativeLabeledRowsSkeleton(rows: 2).frame(width: 430))
        let rowsSize = rows.sizeThatFits(in: NSSize(width: 430, height: 300))
        expect(rowsSize.width == 430)
        expect(rowsSize.height >= 50 && rowsSize.height <= 120)

        let idle = NSHostingController(rootView: NativeAsyncButtonLabel(
            title: "Save changes",
            loadingTitle: "Saving…",
            isLoading: false
        ))
        let loading = NSHostingController(rootView: NativeAsyncButtonLabel(
            title: "Save changes",
            loadingTitle: "Saving…",
            isLoading: true
        ))
        let idleSize = idle.sizeThatFits(in: NSSize(width: 300, height: 100))
        let loadingSize = loading.sizeThatFits(in: NSSize(width: 300, height: 100))
        expect(abs(idleSize.width - loadingSize.width) < 0.5)
        expect(abs(idleSize.height - loadingSize.height) < 0.5)

        let empty = NSHostingController(rootView: NativeStateMessage(
            title: "No activity yet",
            message: "Invite a friend to get started."
        ).frame(width: 350))
        let emptySize = empty.sizeThatFits(in: NSSize(width: 350, height: 400))
        expect(emptySize.width == 350)
        expect(emptySize.height >= 150)
        print("Native loading layout checks passed: \(checks)")
    }
}
