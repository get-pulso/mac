import SwiftUI

struct StatusIcon: View {
    // MARK: Internal

    let avatars: [NSImage]
    let iconSize: CGFloat
    let markColor: Color
    /// The development build's mark: the same mark cut out of a filled tile,
    /// so the copy talking to the local API is told from the released one at
    /// a glance when both sit in the menu bar. With friends online the tile
    /// leads the avatars, which are otherwise the same row in both.
    var inverted = false

    var body: some View {
        if self.avatars.isEmpty {
            if self.inverted {
                self.invertedMark
            } else {
                FirstlightMark()
                    .fill(self.markColor)
                    .frame(width: self.iconSize, height: self.iconSize)
                    .background(Color.clear)
            }
        } else if self.inverted {
            HStack(spacing: Self.invertedGap) {
                self.invertedMark
                self.avatarRow
            }
        } else {
            self.avatarRow
        }
    }

    static func totalWidth(forAvatarCount count: Int, iconSize: CGFloat, inverted: Bool) -> CGFloat {
        let row = self.totalWidth(forAvatarCount: count, iconSize: iconSize)
        return inverted && count > 0 ? iconSize + self.invertedGap + row : row
    }

    static func totalWidth(forAvatarCount count: Int, iconSize: CGFloat) -> CGFloat {
        guard count > 0 else { return iconSize }
        let avatarDiameter = iconSize * 0.9
        let overlap = avatarDiameter * Self.avatarOverlapRatio
        let count = min(count, 3)
        return avatarDiameter + CGFloat(count - 1) * (avatarDiameter - overlap)
    }

    // MARK: Private

    private static let invertedGap: CGFloat = 4

    private static let avatarOverlapRatio: CGFloat = 0.32
    private static let avatarBorderWidth: CGFloat = 0.5

    /// The mark as a hole in a tile. Drawn with alpha alone, so it still
    /// works as a template image and follows the bar's colour.
    private var invertedMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.iconSize * 0.24, style: .continuous)
                .fill(self.markColor)
            FirstlightMark()
                .fill(Color.black)
                .frame(width: self.iconSize * 0.74, height: self.iconSize * 0.74)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: self.iconSize, height: self.iconSize)
    }

    private var avatarRow: some View {
        Group {
            let avatarDiameter = self.iconSize * 0.9
            let overlap = avatarDiameter * Self.avatarOverlapRatio
            let count = min(self.avatars.count, 3)
            let totalWidth = StatusIcon.totalWidth(forAvatarCount: count, iconSize: self.iconSize)
            ZStack(alignment: .leading) {
                ForEach(Array(self.avatars.prefix(3).enumerated()), id: \ .offset) { index, image in
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: avatarDiameter, height: avatarDiameter)
                            .clipShape(Circle())
                        Circle()
                            .stroke(self.markColor.opacity(0.26), lineWidth: Self.avatarBorderWidth)
                            .frame(width: avatarDiameter, height: avatarDiameter)
                    }
                    .offset(x: CGFloat(index) * (avatarDiameter - overlap))
                    .zIndex(Double(index))
                }
            }
            .frame(width: totalWidth, height: self.iconSize, alignment: .leading)
            .background(Color.clear)
        }
    }
}

/// The Firstlight mark: an eclipse crescent with seven rays, laid out in a 128x128 box.
/// Pure outline geometry, so it also reads correctly as a menu bar template image.
private struct FirstlightMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // crescent cusp, lower right
        path.move(to: CGPoint(x: 46.96, y: 112.23))
        path.addArc(
            center: CGPoint(x: 27.2, y: 92.78),
            radius: 27.73,
            startAngle: .degrees(44.54),
            endAngle: .degrees(14.22),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 86.83, y: 106.67))
        path.addArc(
            center: CGPoint(x: 87.39, y: 99.63),
            radius: 7.07,
            startAngle: .degrees(94.59),
            endAngle: .degrees(58.91),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 54.69, y: 96.41))
        path.addArc(
            center: CGPoint(x: 27.2, y: 92.78),
            radius: 27.73,
            startAngle: .degrees(7.53),
            endAngle: .degrees(-1.03),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 106.32, y: 89.88))
        path.addArc(
            center: CGPoint(x: 98.03, y: 82.16),
            radius: 11.33,
            startAngle: .degrees(42.98),
            endAngle: .degrees(10.47),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 54.52, y: 88.01))
        path.addArc(
            center: CGPoint(x: 27.2, y: 92.78),
            radius: 27.73,
            startAngle: .degrees(-9.91),
            endAngle: .degrees(-17.05),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 113.89, y: 66.12))
        path.addArc(
            center: CGPoint(x: 81.09, y: 63.44),
            radius: 32.91,
            startAngle: .degrees(4.67),
            endAngle: .degrees(-14.29),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 51.78, y: 79.95))
        path.addArc(
            center: CGPoint(x: 27.2, y: 92.78),
            radius: 27.73,
            startAngle: .degrees(-27.56),
            endAngle: .degrees(-32.66),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 106.18, y: 37.27))
        path.addArc(
            center: CGPoint(x: 83.82, y: 48.34),
            radius: 24.95,
            startAngle: .degrees(-26.35),
            endAngle: .degrees(-54.69),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 46.88, y: 73.24))
        path.addArc(
            center: CGPoint(x: 27.2, y: 92.78),
            radius: 27.73,
            startAngle: .degrees(-44.8),
            endAngle: .degrees(-49.46),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 82.19, y: 17.81))
        path.addArc(
            center: CGPoint(x: 70.38, y: 50.7),
            radius: 34.95,
            startAngle: .degrees(-70.25),
            endAngle: .degrees(-87.93),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 40.82, y: 68.62))
        path.addArc(
            center: CGPoint(x: 27.2, y: 92.78),
            radius: 27.73,
            startAngle: .degrees(-60.58),
            endAngle: .degrees(-68.96),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 52.35, y: 17.41))
        path.addArc(
            center: CGPoint(x: 53.53, y: 35.22),
            radius: 17.85,
            startAngle: .degrees(-93.8),
            endAngle: .degrees(-117.43),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 33.02, y: 65.67))
        path.addArc(
            center: CGPoint(x: 27.2, y: 92.78),
            radius: 27.73,
            startAngle: .degrees(-77.88),
            endAngle: .degrees(-88.57),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 27.37, y: 32.93))
        path.addArc(
            center: CGPoint(x: 28.37, y: 36.13),
            radius: 3.35,
            startAngle: .degrees(-107.5),
            endAngle: .degrees(-179.91),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: 24.88, y: 65.15))
        path.addArc(
            center: CGPoint(x: 27.2, y: 92.78),
            radius: 27.73,
            startAngle: .degrees(-94.81),
            endAngle: .degrees(-118.43),
            clockwise: true
        )
        path.addArc(
            center: CGPoint(x: 22.78, y: 96.1),
            radius: 29.07,
            startAngle: .degrees(-107.59),
            endAngle: .degrees(33.7),
            clockwise: false
        )
        path.closeSubpath()
        let scale = min(rect.width, rect.height) / 128
        return path.applying(
            CGAffineTransform(translationX: rect.midX - 64 * scale, y: rect.midY - 64 * scale)
                .scaledBy(x: scale, y: scale)
        )
    }
}
