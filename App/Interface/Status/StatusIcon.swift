import SwiftUI

struct StatusIcon: View {
    let phase: Double
    let avatars: [NSImage?]
    let iconSize: CGFloat

    var body: some View {
        if self.avatars.isEmpty {
            RotatingIconView(phase: self.phase)
                .frame(width: self.iconSize, height: self.iconSize)
                .background(Color.clear)
        } else {
            let avatarDiameter = self.iconSize * 0.7
            let overlap: CGFloat = avatarDiameter * 0.35 // 35% overlap
            let count = min(self.avatars.count, 3)
            let totalWidth = StatusIcon.totalWidth(forAvatarCount: count, iconSize: self.iconSize)
            HStack(spacing: self.iconSize * 0.18) { // Always a gap between icon and avatars
                RotatingIconView(phase: self.phase)
                    .frame(width: self.iconSize, height: self.iconSize)
                ZStack(alignment: .leading) {
                    ForEach(Array(self.avatars.prefix(3).enumerated()), id: \ .offset) { index, image in
                        if let image {
                            ZStack {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: avatarDiameter, height: avatarDiameter)
                                    .clipShape(Circle())
                                Circle()
                                    .stroke(Color.green, lineWidth: 1.5)
                                    .frame(width: avatarDiameter, height: avatarDiameter)
                            }
                            .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                            .offset(x: CGFloat(index) * (avatarDiameter - overlap))
                            .zIndex(Double(index))
                        }
                    }
                }
                .frame(width: totalWidth, height: self.iconSize, alignment: .leading)
            }
            .frame(height: self.iconSize)
            .background(Color.clear)
        }
    }

    static func totalWidth(forAvatarCount count: Int, iconSize: CGFloat) -> CGFloat {
        let avatarDiameter = iconSize * 0.7
        let overlap: CGFloat = avatarDiameter * 0.35
        let count = min(count, 3)
        let border: CGFloat = 2 // 1.5pt border, add a bit more for shadow
        return (count > 0 ? avatarDiameter + CGFloat(count - 1) * (avatarDiameter - overlap) : 0) + border
    }
}

private struct RotatingIconView: View {
    let phase: Double
    let rotationAngle: Double = 45 // base degrees

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let scale = min(width, height) / 128.0
            let offsetX = (width - 128 * scale) / 2
            let offsetY = (height - 128 * scale) / 2

            Path { path in
                // SVG path: M63.9975 114V85.9845L14 63.9975H42.0156L63.9975 14V42.0156L114 63.9975H85.9845L63.9975 114Z
                path.move(to: CGPoint(x: 63.9975, y: 114))
                path.addLine(to: CGPoint(x: 63.9975, y: 85.9845))
                path.addLine(to: CGPoint(x: 14, y: 63.9975))
                path.addLine(to: CGPoint(x: 42.0156, y: 63.9975))
                path.addLine(to: CGPoint(x: 63.9975, y: 14))
                path.addLine(to: CGPoint(x: 63.9975, y: 42.0156))
                path.addLine(to: CGPoint(x: 114, y: 63.9975))
                path.addLine(to: CGPoint(x: 85.9845, y: 63.9975))
                path.addLine(to: CGPoint(x: 63.9975, y: 114))
                path.closeSubpath()
            }
            .applying(
                CGAffineTransform(translationX: 0, y: 0)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: offsetX / scale, y: offsetY / scale)
            )
            .fill(Color.white)
            .rotationEffect(.degrees(self.rotationAngle + self.phase * 90), anchor: .center)
            .frame(width: width, height: height)
        }
    }
}
