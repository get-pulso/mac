import AppKit
import SwiftUI

/// Offscreen geometry checks for every shared loading primitive. No window is
/// shown and no network, account, pasteboard, or application action is used.
@main
enum NativeLoadingLayoutChecks {
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

        let editProfileButton = NSHostingController(
            rootView:
            Button("Edit profile", action: {}).nativeSettingsActionButton()
        )
        let copyButton = NSHostingController(
            rootView:
            Button(action: {}) { NativeCopyButtonLabel(title: "Copy", copied: false) }
                .nativeSettingsActionButton()
        )
        let signOutButton = NSHostingController(
            rootView:
            Button(action: {}) {
                NativeAsyncButtonLabel(title: "Sign out…", loadingTitle: "Signing out…", isLoading: false)
            }.nativeSettingsActionButton()
        )
        let removeButton = NSHostingController(
            rootView:
            Button("Remove…", action: {}).nativeSettingsActionButton()
        )
        let primaryButton = NSHostingController(
            rootView:
            Button("Save changes", action: {}).nativeSettingsPrimaryButton()
        )
        let settingsButtonHeights = [
            editProfileButton.sizeThatFits(in: NSSize(width: 300, height: 100)).height,
            copyButton.sizeThatFits(in: NSSize(width: 300, height: 100)).height,
            signOutButton.sizeThatFits(in: NSSize(width: 300, height: 100)).height,
            removeButton.sizeThatFits(in: NSSize(width: 300, height: 100)).height,
            primaryButton.sizeThatFits(in: NSSize(width: 300, height: 100)).height,
        ]
        expect((settingsButtonHeights.max() ?? 0) - (settingsButtonHeights.min() ?? 0) < 0.5)
        expect(NativeSettingsButtonMetrics.fontSize == 13)
        expect(NativeSettingsButtonMetrics.controlSize == .regular)

        let copyIdle = NSHostingController(rootView: NativeCopyButtonLabel(title: "Copy invite link", copied: false))
        let copyDone = NSHostingController(rootView: NativeCopyButtonLabel(title: "Copy invite link", copied: true))
        let copyIdleSize = copyIdle.sizeThatFits(in: NSSize(width: 300, height: 100))
        let copyDoneSize = copyDone.sizeThatFits(in: NSSize(width: 300, height: 100))
        expect(abs(copyIdleSize.width - copyDoneSize.width) < 0.5)
        expect(abs(copyIdleSize.height - copyDoneSize.height) < 0.5)

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
