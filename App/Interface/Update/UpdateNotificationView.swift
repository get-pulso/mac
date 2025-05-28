import Dependencies
import SwiftUI
import WindowAnimation

struct UpdateNotificationView: View {
    @State var hasNewVersion = false

    @Dependency(\.updater) var updater: Updater

    var body: some View {
        HStack {
            Text("New version is available")
            Spacer()
            Button("Update") {
                self.updater.installUpdate()
            }

            Button("Skip") {
                self.updater.skipUpdate()
            }
        }
        .font(.footnote)
        .padding([.leading, .trailing], 12)
        .frame(height: 40)
        .offset(y: self.hasNewVersion ? 0 : -40)
        .frame(height: self.hasNewVersion ? 40 : 0)
        .background(Color.blue.opacity(0.3))
        .onReceive(self.updater.statusPublisher) { status in
            withAnimation {
                switch status {
                case .upToDate:
                    self.hasNewVersion = false
                case .newVersionAvailable:
                    self.hasNewVersion = true
                }
            }
        }
    }
}
