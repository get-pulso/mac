import Foundation

enum BumpEffect: String, CaseIterable, Identifiable, Codable {
    case goodJob = "good_job", onFire = "on_fire", keepGoing = "keep_going", touchGrass = "touch_grass"

    // MARK: Internal

    var id: String { rawValue }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var title: String {
        switch self {
        case .goodJob: "Good job"
        case .onFire: "On fire"
        case .keepGoing: "Keep going"
        case .touchGrass: "Touch grass"
        }
    }

    var symbol: String {
        switch self {
        case .goodJob: "hands.clap.fill"
        case .onFire: "flame.fill"
        case .keepGoing: "arrow.up"
        case .touchGrass: "leaf.fill"
        }
    }

    var duration: Double {
        switch self {
        case .goodJob: 2.65
        case .onFire: 3.6
        case .keepGoing: 2.05
        case .touchGrass: 4.1
        }
    }

    static func forKind(_ kind: String) -> Self {
        if kind == "hard_worker" { return .keepGoing }
        return Self(rawValue: kind) ?? .goodJob
    }
}

/// All displacements are in points. The same clock drives the GPU surface.
/// Sampling analytically makes interruption, replay and inspection deterministic.
struct BumpEffectMotion {
    var x = 0.0
    var y = 0.0
    var rotation = 0.0
    var scaleX = 1.0
    var scaleY = 1.0
    var cardY = 0.0

    static func sample(_ effect: BumpEffect, at time: Double, reduced: Bool) -> Self {
        guard !reduced, time.isFinite, time > 0, time < effect.duration else { return Self() }
        var result = Self()
        let impact = max(0, time - 0.38)
        switch effect {
        case .goodJob:
            let wave = sin(impact * 22) * exp(-impact * 7)
            result.x = wave * -7
            result.rotation = wave * -4
            result.scaleX = 1 - wave * 0.065
            result.scaleY = 1 + wave * 0.045
            result.cardY = sin(max(0, impact - 0.13) * 18) * exp(-max(0, impact - 0.13) * 9) * 1.1
        case .onFire:
            let breath = sin(min(1, impact / 3.0) * .pi)
            result.scaleX = 1 + breath * 0.027
            result.scaleY = result.scaleX
            result.rotation = sin(impact * 5.5) * breath * 0.45
        case .keepGoing:
            let lift = max(0, sin(min(1, impact / 0.95) * .pi))
            let landing = max(0, time - 1.33)
            result.y = -8 * lift + sin(landing * 19) * exp(-landing * 9) * 1.4
            result.scaleX = 1 - lift * 0.025
            result.scaleY = 1 + lift * 0.035
            result.cardY = -2 * max(0, sin(min(1, max(0, time - 0.16) / 0.85) * .pi))
        case .touchGrass:
            let breeze = sin(min(1, impact / 3.7) * .pi)
            result.rotation = sin(impact * 2.2) * breeze * 1.1
        }
        return result
    }
}
