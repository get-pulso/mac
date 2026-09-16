import AppKit
import SwiftUI

private struct AboutFixture: View {
    let text: String
    let width: CGFloat
    @FocusState private var focus: ProfileDraft.Field?
    var body: some View {
        ProfileAboutField(text: .constant(text), focusedField: $focus)
            .font(.system(size: 13)).controlSize(.regular)
            .frame(width: width).fixedSize(horizontal: false, vertical: true)
    }
}

@main
struct ProfileLayoutChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        let values = ["", "A short introduction.", String(repeating: "Long description with spaces. ", count: 9),
                      String(repeating: "A paragraph.\n\n", count: 25), String(repeating: "x", count: 281)]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [390, 460, 650] {
                for value in values {
                    let host = NSHostingView(rootView: AboutFixture(text: value, width: width))
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
                    host.layoutSubtreeIfNeeded()
                    let size = host.fittingSize
                    precondition(abs(size.width - width) < 1, "Profile input overflow")
                    precondition(size.height >= 90 && size.height <= 260, "Unbounded or collapsed bio: \(size)")
                    checks += 2
                }
            }
        }
        print("Profile layout checks passed: \(checks); empty, long, multiline and over-limit text, three widths, light and dark. No UI displayed or profile data changed.")
    }
}
