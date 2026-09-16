import SwiftUI

/// Raycast-style editing screens: a right-aligned label column, one field
/// column, and a footer that names the action and hosts its submit button.
enum NativeFormMetrics {
    static let labelWidth: CGFloat = 96
    static let columnSpacing: CGFloat = 14
    static let fieldMaxWidth: CGFloat = 420
    static let rowSpacing: CGFloat = 16
    static let cornerRadius: CGFloat = 9
    static let fieldHorizontalPadding: CGFloat = 10
    static let fieldVerticalPadding: CGFloat = 7
    static let borderOpacity: CGFloat = 0.13
    static let focusedBorderOpacity: CGFloat = 0.34
    static let surfaceOpacity: CGFloat = 0.035
}

/// Scrolling form body with a pinned footer.
struct NativeFormScreen<Content: View, Footer: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeFormMetrics.rowSpacing, content: content)
                .padding(.horizontal, 20).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0, content: footer)
    }
}

/// One labelled row. The label sits in a fixed trailing-aligned column so
/// every field on the screen starts on the same vertical line.
struct NativeFormRow<Content: View>: View {
    // MARK: Lifecycle

    init(
        _ label: String,
        alignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.alignment = alignment
        self.content = content
    }

    // MARK: Internal

    let label: String
    let alignment: VerticalAlignment
    let content: () -> Content

    var body: some View {
        HStack(alignment: alignment, spacing: NativeFormMetrics.columnSpacing) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: NativeFormMetrics.labelWidth, alignment: .trailing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6, content: content)
                .frame(maxWidth: NativeFormMetrics.fieldMaxWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bordered well that text fields and other editable content sit in.
/// Focus is shown by a stronger neutral border, never the accent colour.
struct NativeFormFieldChrome: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: NativeFormMetrics.cornerRadius, style: .continuous)
        content
            .padding(.horizontal, NativeFormMetrics.fieldHorizontalPadding)
            .padding(.vertical, NativeFormMetrics.fieldVerticalPadding)
            .background(shape.fill(Color.primary.opacity(NativeFormMetrics.surfaceOpacity)))
            .overlay(shape.strokeBorder(
                Color.primary.opacity(
                    self.focused ? NativeFormMetrics.focusedBorderOpacity : NativeFormMetrics.borderOpacity
                ),
                lineWidth: NativeSettingsBorderStyle.width * 2
            ))
            .contentShape(shape)
    }
}

extension View {
    func nativeFormField(focused: Bool = false) -> some View {
        modifier(NativeFormFieldChrome(focused: focused))
    }
}

/// A single-line or growing text field in the form chrome. Focus is tracked
/// by the caller when it also validates; otherwise the field tracks its own.
struct NativeFormTextField: View {
    // MARK: Internal

    let placeholder: String
    @Binding var text: String
    var title: String?
    var lines: ClosedRange<Int>?
    /// Pass when the screen owns focus (for validation on blur).
    var focused: Bool?

    var body: some View {
        Group {
            if let lines {
                TextField(placeholder, text: $text, axis: .vertical).lineLimit(lines)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .multilineTextAlignment(.leading)
        .focused($ownFocus)
        .accessibilityLabel(title ?? placeholder)
        .nativeFormField(focused: focused ?? ownFocus)
    }

    // MARK: Private

    @FocusState private var ownFocus: Bool
}

struct NativeFormHint: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct NativeFormFieldError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Submit button label: the title, replaced by a spinner and progress text
/// while the request runs. The button keeps the wider of the two widths so
/// it does not jump when the request starts.
struct NativeFormSubmitLabel: View {
    let title: String
    var loadingTitle: String
    var isLoading = false

    var body: some View {
        ZStack {
            Text(title).opacity(isLoading ? 0 : 1)
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(loadingTitle)
            }
            .opacity(isLoading ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: isLoading)
        .accessibilityLabel(isLoading ? loadingTitle : title)
    }
}

/// The edit state shown in the window's top-right corner: unsaved changes, or
/// the result of the last save. A running operation is not reported here — the
/// button that started it carries its own spinner, and saying it twice made the
/// corner flash a word for the length of a request.
struct NativeSettingsStatusView: View {
    // MARK: Lifecycle

    init(model: NativeSettingsModel) {
        self.model = model
        self.groups = model.groupSettings
    }

    // MARK: Internal

    @ObservedObject var model: NativeSettingsModel

    var body: some View {
        Group {
            if let status {
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        // The titlebar hands the corner back to the toolbar when there is
        // nothing to say, so the inset belongs to the text, not to the view.
        .padding(.trailing, self.status == nil ? 0 : 14)
        .frame(height: 22)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: status)
        .accessibilityElement(children: .combine)
    }

    // MARK: Private

    @ObservedObject private var groups: NativeGroupsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: String? {
        // While the operation runs the corner says nothing at all: the changes
        // are on their way out, so calling them unsaved is both wrong and a
        // second voice over the button that is already reporting the work.
        if self.model.route.section == .groups {
            return self.groups.hasChanges && !self.groups.busy ? "Unsaved changes" : nil
        }
        guard self.model.route.page == "edit", !self.model.busy else { return nil }
        if self.model.hasProfileChanges { return "Unsaved changes" }
        return self.model.notice
    }
}

/// The actions under a form: cancel on the left, submit on the right, any
/// error above them. The buttons stand on the window itself, with no bar.
struct NativeFormFooter<Content: View>: View {
    var error: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error { NativeInlineError(message: error) }
            HStack(spacing: 10, content: content)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .top) {
            // Scrolled content fades out just above the buttons instead of
            // running underneath them.
            LinearGradient(
                colors: [Color(NSColor.windowBackgroundColor).opacity(0), Color(NSColor.windowBackgroundColor)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 14)
            .offset(y: -14)
            .allowsHitTesting(false)
        }
    }
}

/// The same capsule glass buttons the popover's profile header uses: plain
/// glass for the secondary action, tinted prominent glass for the submit.
private struct NativeFormSubmitButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
                .tint(.accentColor)
        } else {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .tint(.accentColor)
        }
    }
}

private struct NativeFormCancelButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
}

extension View {
    func nativeFormSubmitButton() -> some View { modifier(NativeFormSubmitButtonStyle()) }
    func nativeFormCancelButton() -> some View { modifier(NativeFormCancelButtonStyle()) }
}
