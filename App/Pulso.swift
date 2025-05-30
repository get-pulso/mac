import Dependencies
import MenuBarExtraAccess
import SwiftUI
import WindowAnimation

@main
struct Pulso: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Dependency(\.appRouter) var appRouter: AppRouter
    @State var isMenuPresented: Bool = false

    var body: some Scene {
        MenuBarExtra("Pulso", systemImage: "bolt.heart.fill") {
            AppView(appRouter: self.appRouter)
                .modifier(WindowAnimationModifier(speed: 10))
                .onReceive(self.appRouter.visibilityPublisher) {
                    self.isMenuPresented = $0
                }
        }
        .menuBarExtraStyle(.window)
        .menuBarExtraAccess(isPresented: self.$isMenuPresented)
    }
}
