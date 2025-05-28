import SwiftUI

struct Blur: AnimatableModifier {
    // MARK: Lifecycle

    init(radius: Double = 0) { self.animatableData = radius }

    // MARK: Internal

    var animatableData: Double

    func body(content: Content) -> some View {
        content.blur(radius: self.animatableData)
    }
}

extension AnyTransition {
    static var blur: AnyTransition {
        AnyTransition.modifier(active: Blur(radius: 2.0), identity: .init())
    }
}
