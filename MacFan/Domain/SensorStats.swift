import Foundation

/// Running min/avg/max for one sensor while the app runs. Kept tiny on
/// purpose — a handful of doubles per sensor, no sample retention.
struct SensorSessionStats: Equatable, Sendable {
    private(set) var minimum: Double
    private(set) var maximum: Double
    private(set) var total: Double
    private(set) var count: Int

    init(first: Double) {
        let value = first.isFinite ? first : 0
        minimum = value
        maximum = value
        total = value
        count = first.isFinite ? 1 : 0
    }

    var average: Double { count == 0 ? 0 : total / Double(count) }

    mutating func observe(_ value: Double) {
        guard value.isFinite else { return }
        guard count > 0 else {
            minimum = value
            maximum = value
            total = value
            count = 1
            return
        }
        minimum = min(minimum, value)
        maximum = max(maximum, value)
        total += value
        count += 1
    }
}

enum SensorCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case cpu = "CPU"
    case gpu = "GPU"
    case battery = "Battery"
    case other = "Other"

    var id: String { rawValue }

    static func classify(_ sensor: SensorReading) -> SensorCategory {
        let name = sensor.name.lowercased()
        let key = sensor.key.lowercased()
        if name.contains("gpu") || key.hasPrefix("tg") || key.hasPrefix("gput") { return .gpu }
        if name.contains("battery") || key.hasPrefix("tb") || key.contains("battery") { return .battery }
        if name.contains("cpu") || name.contains("core") || name.contains("performance") || name.contains("efficiency") {
            return .cpu
        }
        if key.hasPrefix("tc") || key.hasPrefix("tp") || key.hasPrefix("te") { return .cpu }
        return .other
    }

    func matches(_ sensor: SensorReading) -> Bool {
        self == .all || Self.classify(sensor) == self
    }
}

enum SensorExport {
    /// CSV of the current readings plus session stats, in °C.
    static func csv(sensors: [SensorReading], stats: [String: SensorSessionStats]) -> String {
        var lines = ["key,name,category,current_c,session_min_c,session_avg_c,session_max_c,samples"]
        for sensor in sensors {
            let stat = stats[sensor.key]
            let key = escape(sensor.key)
            let name = escape(sensor.name)
            let category = escape(SensorCategory.classify(sensor).rawValue)
            let current = format(sensor.celsius)
            let minimum = stat.map { format($0.minimum) } ?? ""
            let average = stat.map { format($0.average) } ?? ""
            let maximum = stat.map { format($0.maximum) } ?? ""
            let samples = stat.map { "\($0.count)" } ?? "0"
            let fields = [key, name, category, current, minimum, average, maximum, samples]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
