import AppKit
import SwiftUI

/// Same numeric transition as the committed DashboardUsersView, scoped to
/// changing whole minutes so refreshes never animate unrelated controls.
struct AnimatedDuration: View {
    // MARK: Internal

    let minutes: Double
    /// How the digits turn over. The default carries a little overshoot,
    /// which is right for a total that changes once; a number being scrubbed
    /// with the pointer passes `.snappy` so it settles instead of bouncing.
    var animation: Animation? = .default

    var body: some View {
        Text(DurationLabel.minutes(minutes))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(DurationLabel.wholeMinutes(minutes))))
            .animation(reduceMotion ? nil : animation, value: DurationLabel.wholeMinutes(minutes))
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

    /// The threshold that keeps fast requests from flashing. A skeleton that
    /// fills space the layout already reserved has nothing to flash against,
    /// so those pass `.zero` and appear with the screen.
    var delay: Duration = .milliseconds(180)
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .opacity(visible ? (pulsing ? 1 : 0.62) : 0)
            .task {
                do { try await Task.sleep(for: delay) } catch { return }
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
    /// Ranked lists lead with a place, so the loading rows reserve that column
    /// and the list does not shift sideways once the real rows arrive.
    var showsPlace = false

    var body: some View {
        HStack(spacing: 0) {
            if showsPlace {
                NativeSkeletonShape(width: 13, height: 14)
                    .frame(width: 20, alignment: .center)
                    .padding(.trailing, 8)
            }
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
}

struct NativePeopleSkeleton: View {
    var rows = 5
    /// Only a ranked list leads with a place, so only its loading rows hold
    /// that column open.
    var showsPlaces = false

    var body: some View {
        NativeDelayedSkeleton {
            VStack(spacing: 0) {
                ForEach(0 ..< rows, id: \.self) { _ in
                    NativePersonSkeleton(showsPlace: showsPlaces)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                }
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

/// One placeholder row shaped like a tracked app: icon, name, duration. The
/// 28pt icon and 10pt gap keep the row dividers on the same 38pt inset the
/// loaded list uses, so nothing shifts when the breakdown arrives.
struct NativeTrackedAppRowSkeleton: View {
    var nameWidth: CGFloat = 104

    var body: some View {
        HStack(spacing: 10) {
            NativeSkeletonShape(width: 28, height: 28, radius: 7)
            NativeSkeletonShape(width: nameWidth, height: 12)
            Spacer(minLength: 8)
            NativeSkeletonShape(width: 34, height: 11)
        }
        .padding(.vertical, 5)
    }
}

/// The profile's app breakdown loads after the rest of the profile, into a
/// panel already sized to hold it. Standing rows describe what is coming; a
/// spinner in the same space describes nothing. Four of them, because that is
/// the height the real section comes back at for four apps, and the rows are
/// what the popover scrolls over if there turn out to be five.
struct NativeTrackedAppsSkeleton: View {
    // MARK: Internal

    var rows = 4

    var body: some View {
        NativeDelayedSkeleton(delay: .zero) {
            // Leading, like the "Top apps" heading it stands in for: a centred
            // bar would slide left when the real text arrives.
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                NativeSkeletonShape(width: 58, height: 12)
                VStack(spacing: 0) {
                    ForEach(0 ..< rows, id: \.self) { index in
                        NativeTrackedAppRowSkeleton(
                            nameWidth: Self.nameWidths[index % Self.nameWidths.count]
                        )
                        if index < rows - 1 { Divider().padding(.leading, 38).opacity(0.5) }
                    }
                }
            }
        }
    }

    // MARK: Private

    /// App names are not all one length, so the rows do not read as a stack of
    /// identical bars while they wait.
    private static let nameWidths: [CGFloat] = [118, 84, 134, 96, 110]
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

/// What stands where a list would, when there is nothing to list: an empty
/// ranking, or one that could not be loaded. A symbol, one line, one thing
/// to do. The block sits in the middle of the space the rows would fill, so
/// the popover keeps its shape instead of opening onto a caption at the top
/// of a void.
struct NativeStateMessage: View {
    // MARK: Internal

    /// An SF Symbol for the situation. None keeps the message text-only.
    var symbol: String?
    let title: String
    /// A second line, only where the title alone would leave a question.
    var message: String?
    /// The error's own words. Not shown: they sit under the pointer on the
    /// title, for whoever wants to report the failure.
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?
    /// The space the message is centred in. Lists pass the height their rows
    /// would take, so the message sits in the middle of it, not at the top.
    var minHeight: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .padding(.bottom, 12)
                    .accessibilityHidden(true)
            }
            Text(title).font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
                .help(detail ?? "")
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if let actionTitle, let action {
                actionButton(actionTitle, action: action).padding(.top, 14)
            }
        }
        .frame(maxWidth: 250)
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .accessibilityElement(children: .contain)
    }

    // MARK: Private

    /// The same capsule the popover's other standalone buttons wear.
    @ViewBuilder private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *) {
            Button(title, action: action)
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
        }
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

    var maximumHeight = NativeLayout.peopleBodyHeight
    var reservesMaximumHeight = false
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
        .coordinateSpace(.named(NativeLayout.popoverScrollSpace))
        .frame(
            height: reservesMaximumHeight
                ? maximumHeight
                : min(maximumHeight, max(44, measuredHeight ?? maximumHeight))
        )
        .onPreferenceChange(ContentHeight.self) { height in
            if abs((measuredHeight ?? -1) - height) > 0.5 { measuredHeight = height }
        }
    }

    // MARK: Private

    private struct ContentHeight: PreferenceKey {
        static var defaultValue: CGFloat { 0 }

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    // Nil until SwiftUI has reported the content's real intrinsic height, and
    // read as this screen's own maximum until then. Starting at any other
    // number means the first frame after a navigation is drawn at a height
    // belonging to no screen, and the window sets off towards it before the
    // measurement arrives a frame later and turns it around.
    @State private var measuredHeight: CGFloat?
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

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let onSubmit = self.parent.onSubmit
            else { return false }
            onSubmit()
            return true
        }
    }

    @Binding var text: String
    /// Return in the field. Nil leaves the key to the default responder chain.
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        // The field sits at the top of the settings sidebar; "settings" is implied.
        field.placeholderString = "Search"
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

/// One pin for every surface that shows where a person is: the people list, the
/// popover profile and the account overview.
/// A paper plane drawn open, with the fold across its body: what a request
/// becomes once it has gone. Drawn rather than an asset so it strokes at the
/// weight its size asks for, at any size.
struct NativeSendIcon: View {
    var size: CGFloat = 12

    var body: some View {
        NativeSendGlyph()
            .stroke(style: StrokeStyle(lineWidth: self.size / 12, lineCap: .round, lineJoin: .round))
            .frame(width: self.size, height: self.size)
    }
}

struct NativeSendGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Authored on a 24 pt grid, scaled to whatever square it is given.
        let scale = min(rect.width, rect.height) / 24
        let originX = rect.minX + (rect.width - 24 * scale) / 2
        let originY = rect.minY + (rect.height - 24 * scale) / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: point(9.61946, 10.8613))
        path.addLine(to: point(20.9997, 4.55422))

        path.move(to: point(9.04735, 10.9043))
        path.addLine(to: point(4.10061, 5.68812))
        path.addCurve(
            to: point(4.82621, 4),
            control1: point(3.49632, 5.05091),
            control2: point(3.94803, 4)
        )
        path.addLine(to: point(20.2513, 4))
        path.addCurve(
            to: point(21.1132, 5.50702),
            control1: point(21.0247, 4),
            control2: point(21.5054, 4.84039)
        )
        path.addLine(to: point(13.1902, 18.9762))
        path.addCurve(
            to: point(11.3654, 18.7393),
            control1: point(12.7433, 19.7358),
            control2: point(11.6035, 19.5879)
        )
        path.addLine(to: point(9.28458, 11.3223))
        path.addCurve(
            to: point(9.04735, 10.9043),
            control1: point(9.24066, 11.1658),
            control2: point(9.15923, 11.0223)
        )
        path.closeSubpath()
        return path
    }
}

/// A ticket, with its stub perforated: an invitation is something you hand
/// someone. Drawn on the same 24 pt grid as the paper plane.
struct NativeInviteIcon: View {
    var size: CGFloat = 13

    var body: some View {
        NativeInviteGlyph()
            .stroke(style: StrokeStyle(lineWidth: self.size / 12, lineCap: .round, lineJoin: .round))
            .frame(width: self.size, height: self.size)
    }
}

struct NativeInviteGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let originX = rect.minX + (rect.width - 24 * scale) / 2
        let originY = rect.minY + (rect.height - 24 * scale) / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: point(19, 5))
        path.addLine(to: point(5, 5))
        path.addCurve(to: point(3, 7), control1: point(3.89543, 5), control2: point(3, 5.89543))
        path.addLine(to: point(3, 9.25))
        path.addCurve(to: point(3, 14.75), control1: point(5.5, 10.25), control2: point(5.5, 13.75))
        path.addLine(to: point(3, 17))
        path.addCurve(to: point(5, 19), control1: point(3, 18.1046), control2: point(3.89543, 19))
        path.addLine(to: point(19, 19))
        path.addCurve(to: point(21, 17), control1: point(20.1046, 19), control2: point(21, 18.1046))
        path.addLine(to: point(21, 14.75))
        path.addCurve(to: point(21, 9.25), control1: point(18.5, 13.75), control2: point(18.5, 10.25))
        path.addLine(to: point(21, 7))
        path.addCurve(to: point(19, 5), control1: point(21, 5.89543), control2: point(20.1046, 5))
        path.closeSubpath()

        // The perforation: three dots, each a stroke too short to be a line.
        for y in [8.5, 12, 15.5] as [CGFloat] {
            path.move(to: point(15, y))
            path.addLine(to: point(15, y + 0.01))
        }
        return path
    }
}

struct NativeLocationIcon: View {
    var size: CGFloat = 11

    var body: some View {
        Image("ProfileLocation")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: self.size, height: self.size)
    }
}

struct NativeLocationLabel: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            NativeLocationIcon(size: self.size - 1)
            Text(self.text).font(.system(size: self.size))
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
