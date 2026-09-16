import Foundation
import ImageIO

struct BumpEmojiClip {
    let frames: [CGImage]
    let ends: [Double]
    let duration: Double

    static func load(_ url: URL) -> Self? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var frames: [CGImage] = []
        var ends: [Double] = []
        var duration = 0.0
        for index in 0 ..< min(180, CGImageSourceGetCount(source)) {
            guard !Task.isCancelled else { return nil }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            let webp = properties?["{WebP}"] as? [String: Any]
            let delay = (webp?["UnclampedDelayTime"] as? Double) ?? (webp?["DelayTime"] as? Double) ?? 1 / 30
            // Keep the original 16/17 ms cadence, including WebP's millisecond rounding.
            duration += max(1 / 120, delay)
            frames.append(image)
            ends.append(duration)
        }
        guard !frames.isEmpty else { return nil }
        return Self(frames: frames, ends: ends, duration: duration)
    }

    func frame(at time: Double) -> CGImage? {
        guard self.duration > 0 else { return self.frames.first }
        let phase = max(0, time).truncatingRemainder(dividingBy: self.duration)
        let index = self.ends.firstIndex(where: { phase < $0 }) ?? max(0, self.frames.count - 1)
        return self.frames.indices.contains(index) ? self.frames[index] : nil
    }
}
