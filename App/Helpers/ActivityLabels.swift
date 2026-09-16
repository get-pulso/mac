import Foundation

enum DurationLabel {
    static func wholeMinutes(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value, Double(Int.max - 1024)))
    }

    static func minutes(_ value: Double) -> String {
        let minutes = self.wholeMinutes(value)
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
