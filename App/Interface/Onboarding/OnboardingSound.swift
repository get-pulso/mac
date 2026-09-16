import AVFoundation
import Foundation
import os

enum OnboardingSoundVariant: String, CaseIterable, Identifiable {
    case warmAnalog = "02"

    // MARK: Internal

    static let preferenceKey = "firstlight.onboarding.sound"
    /// The soundtrack stays at its original speed. The visual choreography
    /// retains the lab's window handoff. The bass crest is aligned earlier,
    /// to the final reveal haptic at 3.75 pacing seconds (4.905882 audio seconds).
    static let windowCue = 5.56

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .warmAnalog: "02 · Warm analog"
        }
    }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: Self.preferenceKey).flatMap(Self.init(rawValue:)) ?? .warmAnalog
    }

    func resourceURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "arrival-\(self.rawValue)", withExtension: "m4a", subdirectory: "OnboardingSounds")
            ?? bundle.url(forResource: "arrival-\(self.rawValue)", withExtension: "m4a")
    }
}

/// One prepared scene, with no separately scheduled accents or repeated notes.
/// The owner keeps the player alive after the visual reveal so its tail finishes.
final class OnboardingSoundPlayer: NSObject, AVAudioPlayerDelegate {
    // MARK: Lifecycle

    deinit { self.stop() }

    // MARK: Internal

    var currentTime: TimeInterval? {
        guard let player, player.isPlaying else { return nil }
        return player.currentTime
    }

    @discardableResult
    func start(_ variant: OnboardingSoundVariant) -> Bool {
        self.stop()
        guard let url = variant.resourceURL() else {
            Self.log.error("Sound resource missing: \(variant.rawValue, privacy: .public)")
            return false
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else {
                Self.log.error("Sound output could not be prepared")
                return false
            }
            self.player = player
            player.delegate = self
            guard self.player === player, player.play() else {
                self.stop()
                return false
            }
            Self.log.notice("Sound \(variant.rawValue, privacy: .public) started, duration \(player.duration)")
            return true
        } catch {
            Self.log.error("Sound unavailable: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func stop() {
        self.player?.stop()
        self.player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        guard self.player === player else { return }
        Self.log.notice("Sound finished")
        self.stop()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: Error?) {
        guard self.player === player else { return }
        self.stop()
    }

    // MARK: Private

    private static let log = Logger(subsystem: "sh.firstlight.mac", category: "OnboardingAudio")

    private var player: AVAudioPlayer?
}
