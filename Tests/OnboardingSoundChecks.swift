import AVFoundation
import Foundation

@main
enum OnboardingSoundChecks {
    static func main() throws {
        let suite = "firstlight.sound-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(OnboardingSoundVariant.allCases.map(\.rawValue) == ["02"])
        precondition(OnboardingSoundVariant.selected(in: defaults) == .warmAnalog)
        for removed in ["04", "10"] {
            defaults.set(removed, forKey: OnboardingSoundVariant.preferenceKey)
            precondition(OnboardingSoundVariant.selected(in: defaults) == .warmAnalog)
        }
        defaults.set("removed-choice", forKey: OnboardingSoundVariant.preferenceKey)
        precondition(OnboardingSoundVariant.selected(in: defaults) == .warmAnalog)
        let bundle = Bundle(path: CommandLine.arguments[1])!
        for variant in OnboardingSoundVariant.allCases {
            defaults.set(variant.rawValue, forKey: OnboardingSoundVariant.preferenceKey)
            precondition(OnboardingSoundVariant.selected(in: UserDefaults(suiteName: suite)!) == variant)
            let url = variant.resourceURL(in: bundle)!
            let player = try AVAudioPlayer(contentsOf: url)
            precondition(abs(player.duration - 16.08) < 0.05)
            precondition(player.numberOfChannels == 2)
            precondition(player.rate == 1 && player.numberOfLoops == 0)
            print("PASS: \(variant.title), saved preference, bundled stereo AAC, \(player.duration) seconds")
        }
    }
}
