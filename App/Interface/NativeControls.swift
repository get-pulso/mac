import AppKit
import SwiftUI

/// Same numeric transition as the committed DashboardUsersView, scoped to
/// changing whole minutes so refreshes never animate unrelated controls.
struct AnimatedDuration: View {
    // MARK: Internal

    let minutes: Double

    var body: some View {
        Text(DurationLabel.minutes(minutes))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(DurationLabel.wholeMinutes(minutes))))
            .animation(reduceMotion ? nil : .default, value: DurationLabel.wholeMinutes(minutes))
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// Reserve the same small footprint, but never flash a spinner for fast work.
struct NativeProgress: View {
    // MARK: Internal

    var active: Bool = true
    var label = "Loading"
    var delay: Duration = .milliseconds(350)

    var body: some View {
        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            .opacity(visible ? 1 : 0)
            .accessibilityLabel(label)
            .accessibilityHidden(!visible)
            .task(id: active) {
                visible = false
                guard active else { return }
                do { try await Task.sleep(for: delay) } catch { return }
                visible = true
            }
    }

    // MARK: Private

    @State private var visible = false
}

struct NativeAsyncButtonLabel: View {
    let title: String
    var loadingTitle: String
    var isLoading: Bool

    var body: some View {
        ZStack {
            Text(title).opacity(isLoading ? 0 : 1)
            HStack(spacing: 6) {
                NativeProgress(active: isLoading, label: loadingTitle, delay: .milliseconds(180))
                Text(loadingTitle)
            }.opacity(isLoading ? 1 : 0)
        }
        .accessibilityLabel(isLoading ? loadingTitle : title)
    }
}

enum NativeSettingsButtonMetrics {
    static let fontSize: CGFloat = 13
    static let controlSize: ControlSize = .regular
}

private struct NativeSettingsButtonMetricsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: NativeSettingsButtonMetrics.fontSize))
            .controlSize(NativeSettingsButtonMetrics.controlSize)
    }
}

extension View {
    func nativeSettingsActionButton() -> some View {
        modifier(NativeSettingsButtonMetricsModifier())
            .buttonStyle(.bordered)
    }

    func nativeSettingsPrimaryButton() -> some View {
        modifier(NativeSettingsButtonMetricsModifier())
            .buttonStyle(.borderedProminent)
    }
}

/// Keeps copy actions stable in size while their feedback swaps in place.
/// The motion combines blur, scale and opacity, and becomes instantaneous
/// when Reduce Motion is enabled.
struct NativeCopyButtonLabel: View {
    // MARK: Internal

    let title: String
    let copied: Bool
    var loadingTitle: String?
    var isLoading = false

    var body: some View {
        ZStack {
            stateText(title, visible: !copied && !isLoading)
            stateText("Copied", visible: copied && !isLoading)
            if let loadingTitle {
                HStack(spacing: 6) {
                    NativeProgress(active: isLoading, label: loadingTitle, delay: .milliseconds(180))
                    Text(loadingTitle)
                }
                .modifier(CopyLabelStateModifier(visible: isLoading))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: copied)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isLoading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLoading ? loadingTitle ?? title : copied ? "Copied" : title)
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func stateText(_ value: String, visible: Bool) -> some View {
        Text(value).modifier(CopyLabelStateModifier(visible: visible))
    }
}

private struct CopyLabelStateModifier: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: self.visible ? 0 : 4)
            .scaleEffect(self.visible ? 1 : 0.92)
            .opacity(self.visible ? 1 : 0)
    }
}

/// A quiet macOS skeleton: structure is visible after a short threshold, so
/// fast requests never flash a loader. Pulse is disabled with Reduce Motion.
struct NativeSkeletonShape: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.10))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

struct NativeDelayedSkeleton<Content: View>: View {
    // MARK: Internal

    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .opacity(visible ? (pulsing ? 1 : 0.62) : 0)
            .task {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                withAnimation(.easeOut(duration: 0.12)) { visible = true }
                startPulse()
            }
            .onChange(of: reduceMotion) { _, value in
                if value { pulsing = true }
                else if visible { startPulse() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var pulsing = false

    private func startPulse() {
        guard !self.reduceMotion else { self.pulsing = true; return }
        self.pulsing = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
    }
}

struct NativePersonSkeleton: View {
    var avatarSize: CGFloat = 40
    var showAction = false

    var body: some View {
        HStack(spacing: 12) {
            NativeSkeletonShape(width: avatarSize, height: avatarSize, radius: avatarSize / 2)
            VStack(alignment: .leading, spacing: 7) {
                NativeSkeletonShape(width: 112, height: 13)
                NativeSkeletonShape(width: 168, height: 10)
            }
            Spacer(minLength: 8)
            if showAction { NativeSkeletonShape(width: 54, height: 22, radius: 6) }
            else { NativeSkeletonShape(width: 34, height: 11) }
        }
    }
}

struct NativePeopleSkeleton: View {
    var rows = 5

    var body: some View {
        NativeDelayedSkeleton {
            VStack(spacing: 0) {
                ForEach(0 ..< rows, id: \.self) { _ in
                    NativePersonSkeleton()
                        .padding(.horizontal, 13).padding(.vertical, 10)
                }
            }
        }
    }
}

struct NativeRowsSkeleton: View {
    var rows = 3
    var showActions = false

    var body: some View {
        NativeDelayedSkeleton {
            VStack(spacing: 12) {
                ForEach(0 ..< rows, id: \.self) { _ in
                    NativePersonSkeleton(avatarSize: 30, showAction: showActions)
                }
            }
        }
    }
}

struct NativeMetricSkeleton: View {
    var body: some View {
        NativeDelayedSkeleton {
            VStack(alignment: .leading, spacing: 12) {
                NativeSkeletonShape(width: 92, height: 22, radius: 5)
                NativeSkeletonShape(width: 230, height: 11)
                Divider()
                NativeSkeletonShape(width: 126, height: 13)
                NativeSkeletonShape(width: 210, height: 10)
            }
        }
    }
}

struct NativeLabeledRowsSkeleton: View {
    var rows = 2

    var body: some View {
        NativeDelayedSkeleton {
            VStack(spacing: 14) {
                ForEach(0 ..< rows, id: \.self) { _ in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            NativeSkeletonShape(width: 104, height: 12)
                            NativeSkeletonShape(width: 148, height: 9)
                        }
                        Spacer()
                        NativeSkeletonShape(width: 48, height: 12)
                    }
                }
            }
        }
    }
}

struct NativeAuthSkeleton: View {
    var body: some View {
        NativeDelayedSkeleton {
            VStack(alignment: .leading, spacing: 12) {
                NativeSkeletonShape(height: 28, radius: 6)
                NativeSkeletonShape(width: 214, height: 11)
                NativeSkeletonShape(height: 32, radius: 7)
            }
        }
    }
}

struct NativeStateMessage: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action { Button(actionTitle, action: action).controlSize(.small) }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(24)
    }
}

struct NativeInlineError: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let retry { Spacer(minLength: 0); Button("Retry", action: retry).controlSize(.small) }
        }.font(.callout).accessibilityElement(children: .contain)
    }
}

struct NativeBackButton: View {
    var help = "Back"
    let action: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Button(action: action) { Image(systemName: "chevron.left").frame(width: 18, height: 22) }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
            } else {
                Button(action: action) { Image(systemName: "chevron.left").frame(width: 18, height: 22) }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
        }
        .help(help).accessibilityLabel(help)
        .keyboardShortcut("[", modifiers: .command)
    }
}

/// Short forms hug their content; only long lists scroll. No 350 pt empty well.
struct PopoverContent<Content: View>: View {
    // MARK: Internal

    var maximumHeight: CGFloat = 410
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12, content: content)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ContentHeight.self, value: geometry.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(maximumHeight, max(44, measuredHeight)))
        .onPreferenceChange(ContentHeight.self) { height in
            if abs(measuredHeight - height) > 0.5 { measuredHeight = height }
        }
    }

    // MARK: Private

    private struct ContentHeight: PreferenceKey {
        static var defaultValue: CGFloat { 0 }

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    // Keep the current list-sized window until SwiftUI reports the detail's
    // real intrinsic height. Starting at an arbitrary short height creates a
    // visible shrink-then-grow bounce on the first navigation.
    @State private var measuredHeight = NativeLayout.peopleBodyHeight
}

struct NativeSearchField: NSViewRepresentable {
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        // MARK: Lifecycle

        init(_ parent: NativeSearchField) { self.parent = parent }

        // MARK: Internal

        var parent: NativeSearchField

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { self.parent.text = field.stringValue }
        }
    }

    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search settings"
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != self.text { field.stringValue = self.text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
}
