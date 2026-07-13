import Foundation

/// Decides when a local notification is warranted. Pure state machine —
/// delivery is the caller's concern. Rules:
///  - the temperature must stay at/above the threshold for `sustainDuration`
///    continuously before a heat alert fires;
///  - after firing, no repeat until the reading falls `hysteresis` below the
///    threshold AND `cooldown` has elapsed;
///  - losing verified fan control while MacFan was actively controlling the
///    fans always produces an alert (at most once per loss).
struct AlertEngine: Sendable {
    struct Event: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case sustainedHeat(celsius: Double)
            case controlLost
        }
        let kind: Kind
    }

    var thresholdCelsius: Double
    var sustainDuration: TimeInterval
    var hysteresis: Double
    var cooldown: TimeInterval

    private var hotSince: Date?
    private var lastHeatAlert: Date?
    private var rearmed = true
    private var hadControlWithActiveMode = false

    init(
        thresholdCelsius: Double = 85,
        sustainDuration: TimeInterval = 60,
        hysteresis: Double = 5,
        cooldown: TimeInterval = 15 * 60
    ) {
        self.thresholdCelsius = thresholdCelsius
        self.sustainDuration = sustainDuration
        self.hysteresis = hysteresis
        self.cooldown = cooldown
    }

    mutating func update(
        temperature: Double?,
        capability: ControlCapability,
        activeMode: FanMode,
        at now: Date = .now
    ) -> [Event] {
        var events: [Event] = []

        // Control loss: only meaningful if we previously had verified control
        // while a non-system mode was engaged.
        let controlling = capability.canControl && activeMode != .system
        if hadControlWithActiveMode, !capability.canControl {
            events.append(Event(kind: .controlLost))
            hadControlWithActiveMode = false
        } else {
            hadControlWithActiveMode = controlling || (hadControlWithActiveMode && capability.canControl)
        }

        guard let temperature, temperature.isFinite, thresholdCelsius.isFinite else {
            hotSince = nil
            return events
        }

        if temperature >= thresholdCelsius {
            if hotSince == nil { hotSince = now }
            let sustained = now.timeIntervalSince(hotSince ?? now) >= sustainDuration
            let cooledDown = lastHeatAlert.map { now.timeIntervalSince($0) >= cooldown } ?? true
            if sustained, rearmed, cooledDown {
                events.append(Event(kind: .sustainedHeat(celsius: temperature)))
                lastHeatAlert = now
                rearmed = false
            }
        } else {
            hotSince = nil
            if temperature <= thresholdCelsius - hysteresis { rearmed = true }
        }
        return events
    }
}
