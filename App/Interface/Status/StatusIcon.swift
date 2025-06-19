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
            HStack(spacing: 0) {
                RotatingIconView(phase: self.phase)
                    .frame(width: self.iconSize, height: self.iconSize)
                ZStack {
                    ForEach(Array(self.avatars.enumerated()), id: \ .offset) { index, image in
                        if let image {
                            ZStack {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: self.iconSize * 0.7, height: self.iconSize * 0.7)
                                    .clipShape(Circle())
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: 1.5)
                                    .frame(width: self.iconSize * 0.7, height: self.iconSize * 0.7)
                            }
                            .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                            .offset(x: CGFloat(index) * (self.iconSize * 0.45))
                            .zIndex(Double(index))
                        }
                    }
                }
                .frame(
                    width: (self.iconSize * 0.7) + CGFloat(max(self.avatars.count - 1, 0)) * (self.iconSize * 0.45),
                    height: self.iconSize
                )
                .padding(.leading, -self.iconSize * 0.2)
                .padding(.trailing, self.iconSize * 0.35)
            }
            .frame(height: self.iconSize)
            .background(Color.clear)
        }
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
