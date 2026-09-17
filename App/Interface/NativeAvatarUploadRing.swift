import SwiftUI

/// A photo on its way up, drawn on the face it is for: an arc runs round the
/// portrait where the presence ring sits, closes into a full ring when the
/// upload lands, and the new face settles into it. A failed upload just lets
/// the arc go — there is nothing to land.
struct NativeAvatarUploadRing: ViewModifier {
    // MARK: Internal

    let isUploading: Bool
    /// Read at the moment the upload ends.
    var failed = false
    var tint: Color = .firstlight

    func body(content: Content) -> some View {
        content
            .scaleEffect(self.landing)
            .overlay {
                if self.reduceMotion {
                    if self.isUploading {
                        Circle().fill(.regularMaterial)
                        ProgressView().controlSize(.small)
                    }
                } else if self.visible {
                    TimelineView(.animation(paused: self.closed)) { clock in
                        // Closing, the arc grows from wherever it had got to.
                        let turn = self.closed ? self.heldTurn : Self.turn(at: clock.date)
                        Circle()
                            .trim(from: 0, to: self.closed ? 1 : 0.28)
                            .stroke(self.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(turn * 360 - 90))
                            .padding(-4)
                    }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: self.isUploading, initial: true) { _, uploading in
                if uploading { self.begin() } else if self.visible { self.end() }
            }
    }

    // MARK: Private

    @State private var visible = false
    @State private var closed = false
    @State private var landing = 1.0
    @State private var heldTurn = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static func turn(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
    }

    private func begin() {
        self.closed = false
        withAnimation(.easeOut(duration: 0.15)) { self.visible = true }
    }

    private func end() {
        guard !self.failed, !self.reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { self.visible = false }
            return
        }
        self.heldTurn = Self.turn(at: .now)
        withAnimation(.easeOut(duration: 0.3)) { self.closed = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.landing = 0.9
            withAnimation(.spring(duration: 0.45, bounce: 0.4)) { self.landing = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.15)) { self.visible = false }
        }
    }
}

extension View {
    func avatarUploadRing(isUploading: Bool, failed: Bool = false) -> some View {
        modifier(NativeAvatarUploadRing(isUploading: isUploading, failed: failed))
    }
}
