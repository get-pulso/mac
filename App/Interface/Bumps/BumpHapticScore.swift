import Foundation

enum BumpHapticScore {
    struct Cue { let time: Double; let impact: Bool }

    static func cues(effect: BumpEffect, reduced: Bool, incoming: Bool) -> [Cue] {
        if reduced { return [.init(time: 0.08, impact: true)] }
        let offset = incoming ? 0.12 : 0.0
        let beats: [(Double, Bool)]
        switch effect {
        case .goodJob: beats = [(0.025, false), (0.15, true), (0.24, false)]
        case .onFire: beats = [(0.04, false), (0.14, false), (0.28, true)]
        case .keepGoing: beats = [(0.03, false), (0.16, false), (0.34, true)]
        case .touchGrass: beats = [(0.06, false), (0.28, true)]
        }
        return beats.map { Cue(time: $0.0 + offset, impact: $0.1) }
    }
}
