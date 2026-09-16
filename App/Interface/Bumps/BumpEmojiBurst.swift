import SwiftUI

@MainActor final class BumpEmojiLibrary: ObservableObject {
    // MARK: Internal

    static let shared = BumpEmojiLibrary()
    static let names = ["thumb", "clap", "muscle", "fire", "seedling", "star", "herb"]

    @Published private(set) var clips: [String: BumpEmojiClip] = [:]
    @Published private(set) var failed = false

    static func names(for effect: BumpEffect) -> [String] {
        switch effect {
        case .goodJob: ["thumb", "clap"]
        case .onFire: ["fire", "star"]
        case .keepGoing: ["muscle", "star"]
        case .touchGrass: ["seedling", "herb"]
        }
    }

    func prepare(_ effect: BumpEffect = .goodJob) async {
        let names = Self.names(for: effect)
        if names.allSatisfy({ clips[$0] != nil }) { return }
        self.generation += 1
        let expected = self.generation
        self.clips = self.clips.filter { names.contains($0.key) }
        let retained = self.clips
        self.decodeTask?.cancel()
        let urls = names.filter { retained[$0] == nil }.compactMap { name -> (String, URL)? in
            // Pre-rendered native frames; no web view or runtime Lottie player.
            guard let url = Bundle.main.url(forResource: name, withExtension: "webp", subdirectory: "BumpEmoji")
            else { return nil }
            return (name, url)
        }
        let task = Task.detached(priority: .userInitiated) {
            var result: [String: BumpEmojiClip] = [:]
            for (name, url) in urls {
                guard !Task.isCancelled else { return result }
                result[name] = BumpEmojiClip.load(url)
            }
            return result
        }
        self.decodeTask = task
        let decoded = await task.value
        guard self.generation == expected else { return }
        self.clips = retained.merging(decoded) { _, new in new }
        self.failed = self.clips.count != names.count
        self.decodeTask = nil
    }

    // MARK: Private

    private var generation = 0
    private var decodeTask: Task<[String: BumpEmojiClip], Never>?
}

struct BumpEmojiBurst: View {
    // MARK: Internal

    let run: BumpEffectRun?
    let origin: CGPoint

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / 60, paused: run == nil || run?.frozenTime != nil)) { clock in
                if let run {
                    let time = run.elapsed(at: clock.date)
                    ZStack(alignment: .topLeading) {
                        if run.reduced {
                            // One still, in place. No sprite playback, perspective or travelling particles.
                            if let image = library.clips[asset(run.effect, index: 8)]?.frame(at: 0) {
                                Image(decorative: image, scale: 2)
                                    .resizable().scaledToFit().frame(width: 46, height: 46)
                                    .opacity(max(0, sin(min(1, max(0, time / run.duration)) * .pi)))
                                    .position(x: origin.x, y: origin.y - 46)
                            }
                        } else {
                            sparks(time: time, size: geometry.size, effect: run.effect)
                            ForEach(BumpBurstMotion.particles) { particle in
                                let pose = BumpBurstMotion.sample(
                                    particle,
                                    effect: run.effect,
                                    time: time,
                                    origin: origin,
                                    size: geometry.size,
                                    reduced: false,
                                    incoming: run.incoming
                                )
                                if pose.opacity > 0,
                                   let image = library.clips[asset(run.effect, index: particle.id)]?
                                   .frame(at: max(0, time - particle.delay) + Double(particle.id % 4) * 0.17)
                                {
                                    Image(decorative: image, scale: 2)
                                        .resizable().scaledToFit()
                                        .frame(width: particle.size, height: particle.size)
                                        .rotation3DEffect(
                                            .degrees(pose.yaw),
                                            axis: (x: 0, y: 1, z: 0),
                                            perspective: 0.45
                                        )
                                        .rotation3DEffect(
                                            .degrees(pose.pitch),
                                            axis: (x: 1, y: 0, z: 0),
                                            perspective: 0.35
                                        )
                                        .rotationEffect(.degrees(pose.roll))
                                        .scaleEffect(pose.scale)
                                        .shadow(
                                            color: .black.opacity(0.13 * particle.depth),
                                            radius: 2 + 3 * particle.depth,
                                            x: 0,
                                            y: 3 * particle.depth
                                        )
                                        .opacity(pose.opacity)
                                        .position(x: pose.x, y: pose.y)
                                }
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Private

    @ObservedObject private var library = BumpEmojiLibrary.shared

    private func asset(_ effect: BumpEffect, index: Int) -> String {
        switch effect {
        case .goodJob: index == 2 || index == 4 || index == 7 ? "clap" : "thumb"
        case .onFire: index == 1 || index == 3 || index == 5 ? "star" : "fire"
        case .keepGoing: index == 0 || index == 2 || index == 5 ? "star" : "muscle"
        case .touchGrass: index == 0 || index == 3 || index == 6 ? "herb" : "seedling"
        }
    }

    private func sparks(time: Double, size: CGSize, effect: BumpEffect) -> some View {
        Canvas { context, _ in
            for index in 0 ..< 10 {
                let age = time - 0.06 * Double(index % 4)
                guard age > 0, age < 1.65 else { continue }
                let progress = 1 - exp(-age * 3.8)
                let target = CGPoint(x: 25 + Double(index * 71 % 295), y: 70 + Double(index * 97 % 230))
                let x = origin.x + (target.x - origin.x) * progress
                let y = origin.y + (target.y - origin.y) * progress - sin(progress * .pi) * 22
                let radius = (index % 3 == 0 ? 4.0 : 2.3) * sin(age / 1.65 * .pi)
                var diamond = Path()
                diamond.move(to: CGPoint(x: x, y: y - radius))
                diamond.addQuadCurve(to: CGPoint(x: x + radius, y: y), control: CGPoint(x: x + 0.5, y: y - 0.5))
                diamond.addQuadCurve(to: CGPoint(x: x, y: y + radius), control: CGPoint(x: x + 0.5, y: y + 0.5))
                diamond.addQuadCurve(to: CGPoint(x: x - radius, y: y), control: CGPoint(x: x - 0.5, y: y + 0.5))
                diamond.addQuadCurve(to: CGPoint(x: x, y: y - radius), control: CGPoint(x: x - 0.5, y: y - 0.5))
                let color: Color = effect == .touchGrass ? .green : (index.isMultiple(of: 2) ? .pink : .cyan)
                context.opacity = 0.75 * sin(age / 1.65 * .pi)
                context.fill(diamond, with: .color(color))
            }
        }
    }
}
