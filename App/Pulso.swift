import Dependencies
import SwiftUI
import WindowAnimation

@main
struct Pulso: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @Dependency(\.appRouter) var appRouter: AppRouter

    var body: some Scene {
        MenuBarExtra("Pulso", systemImage: "bolt.heart.fill") {
            AppView(appRouter: self.appRouter)
                .modifier(WindowAnimationModifier(speed: 10))
        }
        .menuBarExtraStyle(.window)
    }
}
