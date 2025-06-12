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
        MenuBarExtra {
            VStack(spacing: 0) {
                AppView(appRouter: self.appRouter)
                    .modifier(
                        WindowAnimationModifier(
                            speed: 10,
                            animation: .forInterfaceAnimation
                        )
                    )
                    .onReceive(self.appRouter.visibilityPublisher) {
                        self.isMenuPresented = $0
                    }
                Spacer() // ensures content is top aligned during window animation
            }
        } label: {
            AppIcon()
        }
        .menuBarExtraStyle(.window)
        .menuBarExtraAccess(isPresented: self.$isMenuPresented)
    }
}
