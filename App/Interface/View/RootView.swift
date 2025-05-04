import SwiftUI

struct RootView: View {
    @StateObject var model = try! DataProvider()

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(time: self.$model.todayTime, onTerminate: self.model.terminate)
            ActivityView(activities: self.$model.todayActivities)
        }
        .frame(width: 200, height: 320)
    }
}
