import Foundation

struct SmartBoostPolicy: Codable, Equatable, Sendable {
    var triggerCelsius: Double = 85
    var cooldownDelta: Double = 10
    var cooldownHold: TimeInterval = 60

    func validates() -> Bool {
        (60...95).contains(triggerCelsius) && (5...25).contains(cooldownDelta) && (15...300).contains(cooldownHold)
    }

    // Named presets. Apple laptops throttle around 100–105 °C, so all three
    // triggers sit well below the safe ceiling; the difference is how eagerly
    // the fans ramp and how long they hold once engaged.
    //
    // Comfort keeps the chassis off-the-lap cool: it ramps at 80 °C — before
    // the bottom case turns uncomfortably warm — and, once engaged, holds the
    // fans up for a full five minutes after the CPU settles so it never
    // stutters on and off.
    static let comfort = SmartBoostPolicy(triggerCelsius: 80, cooldownDelta: 8, cooldownHold: 300)
    static let balanced = SmartBoostPolicy(triggerCelsius: 85, cooldownDelta: 10, cooldownHold: 120)
    static let quiet = SmartBoostPolicy(triggerCelsius: 90, cooldownDelta: 12, cooldownHold: 60)

    /// The preset this policy currently matches, if any (for UI selection).
    var presetName: String? {
        switch self {
        case .comfort: "Comfort"
        case .balanced: "Balanced"
        case .quiet: "Quiet"
        default: nil
        }
    }
}

struct SmartBoostEngine: Sendable {
    private(set) var isBoosting = false
    private var cooldownStartedAt: Date?
    var policy: SmartBoostPolicy

    init(policy: SmartBoostPolicy = SmartBoostPolicy()) {
        self.policy = policy
    }

    /// Applies an edited policy without forgetting whether Max is currently
    /// engaged. Rebuilding the engine while boosting would lose that fact and
    /// could leave a verified Max request active while the UI says only
    /// "Armed". A policy edit does restart any in-progress cooldown hold so the
    /// newly displayed thresholds own the full hysteresis decision.
    mutating func updatePolicy(_ nextPolicy: SmartBoostPolicy) {
        guard policy != nextPolicy else { return }
        policy = nextPolicy
        cooldownStartedAt = nil
    }

    mutating func update(temperature: Double?, at date: Date = .now) -> Bool {
        guard let temperature, policy.validates() else {
            reset()
            return false
        }

        if !isBoosting, temperature >= policy.triggerCelsius {
            isBoosting = true
            cooldownStartedAt = nil
            return true
        }

        guard isBoosting else { return false }
        if temperature > policy.triggerCelsius - policy.cooldownDelta {
            cooldownStartedAt = nil
            return true
        }

        if cooldownStartedAt == nil {
            cooldownStartedAt = date
            return true
        }

        if let cooldownStartedAt, date.timeIntervalSince(cooldownStartedAt) >= policy.cooldownHold {
            isBoosting = false
            self.cooldownStartedAt = nil
        }
        return isBoosting
    }

    mutating func reset() {
        isBoosting = false
        cooldownStartedAt = nil
    }
}
