import AppKit

/// The system chooses the available trackpad and respects its feedback settings.
/// AppKit offers discrete patterns, not adjustable vibration intensity.
enum NativeHaptics {
    static func introPulse() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
    }

    static func introClimax() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
    }

    static func introRiseStarted() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
    }

    static func introRiseEnded() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    static func groupCrossing() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    static func groupPlaced() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
    }
}
