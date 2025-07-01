import SwiftUI

struct DefaultAvatarView: View {
    // MARK: Internal

    let identifier: String
    let size: Double

    var body: some View {
        ZStack {
            self.primaryColor
                .overlay(
                    Circle()
                        .fill(self.secondaryColor.opacity(0.2))
                        .scaleEffect(0.8)
                )

            Image(systemName: "face.smiling")
                .font(.system(size: self.size * 0.5, weight: .medium))
                .foregroundColor(.white)
        }
    }

    // MARK: Private

    private var primaryColor: Color {
        let colors: [Color] = [
            .red, .orange, .yellow, .green, .mint, .teal,
            .cyan, .blue, .indigo, .purple, .pink, .brown,
        ]
        let index = self.consistentHash(self.identifier) % colors.count
        return colors[index]
    }

    private var secondaryColor: Color {
        let colors: [Color] = [
            .pink, .purple, .indigo, .blue, .cyan, .teal,
            .mint, .green, .yellow, .orange, .red, .brown,
        ]
        let index = self.consistentHash(self.identifier + "secondary") % colors.count
        return colors[index]
    }

    private func consistentHash(_ string: String) -> Int {
        var hash = 0
        for char in string.utf8 {
            hash = 31 &* hash &+ Int(char)
        }
        return abs(hash)
    }
}
