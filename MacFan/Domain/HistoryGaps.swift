import Foundation

extension Array where Element == TelemetrySample {
    /// Splits an ordered history into contiguous runs so charts can render
    /// missing periods (sleep, app not running) as gaps instead of drawing a
    /// line that connects unrelated samples across hours of silence.
    func contiguousSegments(maxGap: TimeInterval) -> [[TelemetrySample]] {
        guard let first else { return [] }
        var segments: [[TelemetrySample]] = [[first]]
        for sample in dropFirst() {
            if let previous = segments[segments.count - 1].last,
               sample.timestamp.timeIntervalSince(previous.timestamp) > maxGap {
                segments.append([sample])
            } else {
                segments[segments.count - 1].append(sample)
            }
        }
        return segments
    }
}
