import CoreGraphics
import Foundation

/// A bounded fan originating at the measured capsule, sampled without timers or mutable particles.
enum BumpBurstMotion {
    // MARK: Internal

    struct Particle: Identifiable {
        let id: Int
        let x: Double
        let y: Double
        let size: Double
        let depth: Double
        let delay: Double
    }

    struct Pose {
        var x = 0.0
        var y = 0.0
        var scale = 0.0
        var opacity = 0.0
        var roll = 0.0
        var yaw = 0.0
        var pitch = 0.0
    }

    // Back to front. Large foreground gestures leave breathing room around the face.
    static let particles: [Particle] = [
        .init(id: 0, x: 0.22, y: 0.22, size: 30, depth: 0.10, delay: 0.08),
        .init(id: 1, x: 0.65, y: 0.12, size: 27, depth: 0.15, delay: 0.16),
        .init(id: 2, x: 0.89, y: 0.38, size: 34, depth: 0.25, delay: 0.04),
        .init(id: 3, x: 0.12, y: 0.58, size: 42, depth: 0.35, delay: 0.13),
        .init(id: 4, x: 0.43, y: 0.39, size: 49, depth: 0.45, delay: 0.21),
        .init(id: 5, x: 0.27, y: 0.80, size: 35, depth: 0.40, delay: 0.28),
        .init(id: 6, x: 0.77, y: 0.66, size: 57, depth: 0.65, delay: 0.18),
        .init(id: 7, x: 0.78, y: 0.25, size: 67, depth: 0.80, delay: 0.07),
        .init(id: 8, x: 0.45, y: 0.65, size: 93, depth: 1.00, delay: 0.00),
    ]

    static func sample(
        _ particle: Particle,
        effect: BumpEffect,
        time: Double,
        origin: CGPoint,
        size: CGSize,
        reduced: Bool,
        incoming: Bool = false
    ) -> Pose {
        guard time.isFinite, !reduced else { return Pose() }
        let life = min(effect.duration - 0.08, effect == .touchGrass ? 3.05 : 2.6) - particle.delay
        let age = time - particle.delay
        guard age > 0, age < life else { return Pose() }
        let u = age / life
        let travel = (1 - exp(-u * 5)) / (1 - exp(-5.0))
        let flutter = effect == .touchGrass ? 16.0 : 5.0
        let ring: [(Double, Double)] = [
            (0.14, 0.20),
            (0.88, 0.12),
            (0.89, 0.71),
            (0.09, 0.59),
            (0.89, 0.47),
            (0.21, 0.81),
            (0.71, 0.80),
            (0.19, 0.36),
            (0.80, 0.30),
        ]
        let destinationX = (incoming ? ring[particle.id].0 : particle.x) * size.width
        let destinationY = (incoming ? ring[particle.id].1 : particle.y) * size.height
        let fade = 1 - self.smooth(0.64, 1, u)
        let bloom = 1 - exp(-age * 14)
        return Pose(
            x: origin.x + (destinationX - origin.x) * travel
                + sin(u * .pi * 3 + Double(particle.id)) * sin(u * .pi) * flutter,
            y: origin.y + (destinationY - origin.y) * travel - sin(u * .pi) * 27 + u * u * 26,
            scale: (0.12 + 0.88 * bloom) * (1 + sin(u * .pi) * particle.depth * 0.12),
            opacity: self.smooth(0, 0.075, age) * fade * (0.76 + particle.depth * 0.24),
            roll: sin(u * 3.8 + Double(particle.id) * 1.9) * (effect == .touchGrass ? 28 : 17),
            yaw: sin(u * 5 + Double(particle.id) * 1.7) * (16 + particle.depth * 19),
            pitch: cos(u * 3.5 + Double(particle.id)) * 16
        )
    }

    // MARK: Private

    private static func smooth(_ a: Double, _ b: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
