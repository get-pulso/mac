import CoreGraphics
import Foundation
import ImageIO

@main enum BumpEmojiChecks {
    static func main() {
        var samples = 0
        for effect in BumpEffect.allCases {
            for incoming in [false, true] {
                for particle in BumpBurstMotion.particles {
                    for time in stride(from: -0.1, through: effect.duration + 0.1, by: 0.01) {
                        let pose = BumpBurstMotion.sample(particle, effect: effect, time: time,
                            origin: incoming ? CGPoint(x: 175, y: 143) : CGPoint(x: 289, y: 375),
                            size: CGSize(width: 350, height: 405), reduced: false, incoming: incoming)
                        precondition([pose.x, pose.y, pose.scale, pose.opacity, pose.roll, pose.yaw, pose.pitch].allSatisfy(\.isFinite))
                        precondition((0 ... 1).contains(pose.opacity))
                        if pose.opacity > 0.01 {
                            precondition(pose.x > 0 && pose.x < 350 && pose.y > 0 && pose.y < 405)
                        }
                        if time >= effect.duration { precondition(pose.opacity == 0) }
                        let reduced = BumpBurstMotion.sample(particle, effect: effect, time: time,
                            origin: .zero, size: .zero, reduced: true, incoming: incoming)
                        precondition(reduced.opacity == 0)
                        samples += 1
                    }
                }
                let cues = BumpHapticScore.cues(effect: effect, reduced: false, incoming: incoming)
                precondition((2 ... 3).contains(cues.count))
                precondition(cues.filter(\.impact).count == 1)
                precondition(cues.map(\.time) == cues.map(\.time).sorted())
                precondition(cues.allSatisfy { $0.time > 0 && $0.time < 0.6 })
                precondition(BumpHapticScore.cues(effect: effect, reduced: true, incoming: incoming).count == 1)
            }
        }
        print("\(samples) particle samples passed: bounds, finite transforms, completion, reduced motion; haptic scores passed")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var sizes: [String: Int] = [:]
        for name in ["thumb", "clap", "muscle", "fire", "seedling", "star", "herb"] {
            let clip = BumpEmojiClip.load(directory.appendingPathComponent(name + ".webp"))!
            precondition(clip.frames.count >= 80 && clip.duration > 0)
            let authoredFrames = name == "thumb" ? 116 : name == "clap" ? 130 : name == "seedling" ? 120 : 180
            precondition(abs(clip.duration - Double(authoredFrames) / 60) < 0.002, "preserve vector timing")
            let delays = zip([0.0] + clip.ends.dropLast(), clip.ends).map { $0.1 - $0.0 }
            // WebP merges the thumb's 30 identical held frames into one 500 ms frame.
            let moving = delays.filter { $0 < 0.04 }
            precondition(moving.count >= 80 && moving.allSatisfy { $0 >= 0.0159 && $0 <= 0.0171 },
                         "every changing artwork frame must retain 60 fps cadence")
            sizes[name] = clip.frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            for frame in clip.frames { precondition(frame.width <= 160 && frame.height <= 160) }
            precondition(clip.frame(at: 0) != nil && clip.frame(at: 1.3) != nil)
            print(name, clip.frames.count, String(format: "%.3f s", clip.duration))
        }
        let pairs = [["thumb", "clap"], ["fire", "star"], ["muscle", "star"], ["seedling", "herb"]]
        let peak = pairs.map { pair in pair.reduce(0) { $0 + sizes[$1]! } }.max()!
        precondition(peak < 40 * 1048576, "active decoded artwork pair must stay below 40 MiB")
        print(String(format: "Peak active artwork pair: %.1f MiB", Double(peak) / 1048576))
    }
}
