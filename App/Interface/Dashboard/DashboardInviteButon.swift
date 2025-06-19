import SwiftUI

struct DashboardInviteButon: View {
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("Invite")
                    .font(.system(size: 12, weight: .bold))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(18)
            .shadow(radius: 4, y: 1)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Invite")
    }
}
