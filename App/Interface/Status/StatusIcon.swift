import SwiftUI

struct StatusIcon: View {
    let phase: Double
    let avatars: [NSImage]
    let containerHeight: CGFloat

    var body: some View {
        if self.avatars.isEmpty {
            RotatingIconView(phase: self.phase)
                .frame(width: self.containerHeight, height: self.containerHeight)
        } else {
            let avatarDiameter = self.containerHeight * 0.8
            let overlap: CGFloat = avatarDiameter * 0.35 // 35% overlap
            let totalWidth = avatarDiameter + CGFloat(self.avatars.count - 1) * (avatarDiameter - overlap) + 4
            ZStack(alignment: .leading) {
                ForEach(Array(self.avatars.enumerated()), id: \.offset) { index, image in
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
                    .frame(width: avatarDiameter, height: avatarDiameter)
                    .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .offset(x: CGFloat(index) * (avatarDiameter - overlap) + 2)
                    .zIndex(Double(index))
                }
            }
            .frame(width: totalWidth, height: self.containerHeight, alignment: .leading)
        }
    }
}

private struct RotatingIconView: View {
    let phase: Double

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
            .rotationEffect(.degrees(self.phase * 90), anchor: .center)
            .frame(width: width, height: height)
        }
    }
}
