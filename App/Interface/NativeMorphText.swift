import SwiftUI

/// A one-line text that changes the way Family's labels do: the letters the
/// old and the new text share keep their identity and glide sideways to where
/// they now belong, the letters that left fade where they stood, and the new
/// ones come up in place a beat later. Nothing moves up or down — that axis
/// belongs to digits rolling over. "In Figma" becomes "In Xcode" with its
/// "In " standing still; "Try again" becomes "Trying…" on its "Try".
///
/// Drawn letter by letter, a text cannot lose its tail to an ellipsis, so
/// where the line is too narrow the plain truncating text stands in.
struct NativeMorphText: View {
    // MARK: Lifecycle

    init(_ text: String) {
        self.text = text
        _glyphs = State(initialValue: Self.fresh(text, from: 0))
        _nextID = State(initialValue: text.count)
    }

    // MARK: Internal

    /// Torph's defaults, which are Family's feel: one long ease-out, the fades
    /// a fraction of it.
    static let duration = 0.4
    static let glide: Animation = .timingCurve(0.19, 1, 0.22, 1, duration: duration)

    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(self.glyphs) { glyph in
                    Text(String(glyph.character))
                        .transition(self.reduceMotion ? .opacity : Self.letter)
                }
            }
            .fixedSize()
            Text(self.text).lineLimit(1).truncationMode(.tail)
        }
        .onChange(of: self.text) { _, new in
            let (glyphs, used) = Self.morph(self.glyphs, into: new, from: self.nextID)
            self.nextID = used
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.12) : Self.glide) { self.glyphs = glyphs }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.text)
    }

    // MARK: Private

    private struct Glyph: Identifiable, Equatable {
        let id: Int
        let character: Character
    }

    /// Leaving is quick, arriving waits for it: the two never sit on top of
    /// each other at full strength.
    private static let letter: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.95).combined(with: .opacity)
            .animation(.linear(duration: duration * 0.5).delay(duration * 0.25)),
        removal: .scale(scale: 0.95).combined(with: .opacity)
            .animation(.linear(duration: duration * 0.25))
    )

    @State private var glyphs: [Glyph]
    @State private var nextID: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static func fresh(_ text: String, from id: Int) -> [Glyph] {
        text.enumerated().map { Glyph(id: id + $0.offset, character: $0.element) }
    }

    /// The new text's letters, each carrying the identity of the old letter it
    /// is — by the longest common subsequence, so a shared run survives even
    /// when something is inserted ahead of it — or a new identity.
    private static func morph(_ old: [Glyph], into text: String, from id: Int) -> ([Glyph], Int) {
        let new = Array(text)
        let n = old.count
        let m = new.count
        guard n > 0, m > 0 else { return (self.fresh(text, from: id), id + m) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i].character == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        // Walk the table for the letters both texts have, in order.
        var pairs: [(old: Int, new: Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if old[i].character == new[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        // A lone letter in common is a coincidence, not a link: the scattered
        // o and n of "Skip for now" and "Continue" gliding about would say the
        // two are related. Only a run the texts share keeps its identity, and
        // under three letters in all the whole text hands over on the spot.
        var kept: [Int: Int] = [:]
        var run: [(old: Int, new: Int)] = []
        func close() {
            if run.count >= 2 { for pair in run { kept[pair.new] = pair.old } }
            run = []
        }
        for pair in pairs {
            if let last = run.last, last.old + 1 != pair.old || last.new + 1 != pair.new { close() }
            run.append(pair)
        }
        close()
        guard kept.count >= 3 else { return (self.fresh(text, from: id), id + m) }
        var result: [Glyph] = []
        var next = id
        for (index, character) in new.enumerated() {
            if let source = kept[index] {
                result.append(old[source])
            } else {
                result.append(Glyph(id: next, character: character))
                next += 1
            }
        }
        return (result, next)
    }
}
