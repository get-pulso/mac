import AppKit
import SwiftUI

/// How a place is painted in the ranking.
///
/// The first three are metal: a vertical gradient, lighter at the top, so the
/// numeral catches a highlight the way a struck medal does. Flat medal colours
/// were tried first and read as a status tag rather than a position, and a flat
/// silver is indistinguishable from the ordinary grey the rest of the column
/// uses. The gradient carries the distinction even where the hue cannot.
///
/// Everything below third place stays hierarchical grey, so the eye finds the
/// podium without the column turning into a second score.
enum LeaderboardPlaceStyle {
    // MARK: Internal

    static func numeral(for place: Int?) -> AnyShapeStyle {
        guard let medal = LeaderboardPlace.medal(for: place) else { return AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(self.metal(medal))
    }

    static func weight(for place: Int?) -> Font.Weight {
        LeaderboardPlace.medal(for: place) == nil ? .regular : .semibold
    }

    // MARK: Private

    /// Light mode darkens the metal so it holds against a white row; dark mode
    /// lifts it so it does not sink into the background. Both ends of each
    /// gradient come from the same hue, a shade apart.
    private static func metal(_ medal: LeaderboardPlace.Medal) -> LinearGradient {
        let stops: (light: (top: Int, bottom: Int), dark: (top: Int, bottom: Int)) = switch medal {
        case .gold: (light: (0xD49A1E, 0x946306), dark: (0xF7D070, 0xC48A20))
        case .silver: (light: (0xA6ACB4, 0x6E747C), dark: (0xE4E9EF, 0x969DA6))
        case .bronze: (
                light: (0xCB8446, 0x8A5022),
                dark: (0xE8A972, 0xAC6D35)
            )
        }
        return LinearGradient(
            colors: [
                self.dynamic(light: stops.light.top, dark: stops.dark.top),
                self.dynamic(light: stops.light.bottom, dark: stops.dark.bottom),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// One colour that answers for both appearances. Resolved by AppKit at draw
    /// time, so a row does not need to watch the colour scheme to repaint.
    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return self.color(isDark ? dark : light)
        })
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
