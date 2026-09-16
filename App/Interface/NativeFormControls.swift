import SwiftUI

/// One continuous track with one moving selection, independent of the labels' intrinsic widths.
struct NativeTabList<Selection: Hashable>: View {
    // MARK: Internal

    let title: String
    let options: [(title: String, value: Selection)]
    /// The labels' size. Every segment is as wide as the track divided by
    /// their number, never as wide as its own words, so the longest label
    /// decides what fits: a track carrying one long option needs less than
    /// the default, which suits a word or two.
    var labelSize: CGFloat = 13
    @Binding var selection: Selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: labelSize, weight: .medium))
                        .foregroundStyle(selection == option.value ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        // A label squeezed by a narrow window gives up a
                        // little size rather than its last word: "Just the
                        // to…" hides the one option a reader most needs to
                        // be able to read.
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .focused($focusedOption, equals: option.value)
                .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geometry in
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.15) : Color.white.opacity(0.94))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.10), radius: 2, y: 1)
                    .frame(width: geometry.size.width / CGFloat(max(options.count, 1)))
                    .offset(x: geometry.size.width * CGFloat(selectedIndex) / CGFloat(max(options.count, 1)))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(3)
        .background {
            if #available(macOS 26.0, *), !reduceTransparency {
                Color.clear.glassEffect(.regular, in: .capsule)
            } else {
                Capsule().fill(Color(NSColor.controlBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onMoveCommand { direction in
            let nextIndex: Int
            switch direction {
            case .left: nextIndex = max(0, selectedIndex - 1)
            case .right: nextIndex = min(options.count - 1, selectedIndex + 1)
            default: return
            }
            guard options.indices.contains(nextIndex) else { return }
            selection = options[nextIndex].value
            focusedOption = selection
        }
    }

    // MARK: Private

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focusedOption: Selection?

    private var selectedIndex: Int { self.options.firstIndex { $0.value == selection } ?? 0 }
}

/// Uses the same regular system button metrics as Save, Create group, and other form actions.
struct NativePrimaryButton: View {
    let title: String
    let loadingTitle: String
    let isLoading: Bool
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NativeAsyncButtonLabel(title: title, loadingTitle: loadingTitle, isLoading: isLoading)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(.firstlight)
        .controlSize(.regular)
        .disabled(isLoading)
    }
}
