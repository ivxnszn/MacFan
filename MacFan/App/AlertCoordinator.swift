import Combine
import Foundation
import UserNotifications

/// Bridges the pure AlertEngine to UNUserNotificationCenter. Heat alerts are
/// opt-in via Settings; a control-loss alert is always delivered because the
/// user needs to know MacFan handed the fans back to macOS unexpectedly.
@MainActor
final class AlertCoordinator {
    private var engine: AlertEngine
    private let model: AppModel
    private let settings: AppSettings
    private var subscriptions = Set<AnyCancellable>()
    private var requestedAuthorization = false

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        engine = AlertEngine(thresholdCelsius: settings.alertThresholdCelsius)

        Publishers.CombineLatest3(model.$snapshot, model.$capability, model.$activeMode)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.evaluate() }
            .store(in: &subscriptions)
        settings.$alertThresholdCelsius
            .sink { [weak self] threshold in self?.engine.thresholdCelsius = threshold }
            .store(in: &subscriptions)
        settings.$alertsEnabled
            .dropFirst()
            .sink { [weak self] enabled in if enabled { self?.requestAuthorizationIfNeeded() } }
            .store(in: &subscriptions)
    }

    private func evaluate() {
        // Feeding nil temperature disables the heat path (and its state)
        // without touching control-loss tracking.
        let temperature = settings.alertsEnabled ? model.snapshot.displayTemperature?.celsius : nil
        let events = engine.update(
            temperature: temperature,
            capability: model.capability,
            activeMode: model.activeMode
        )
        for event in events {
            switch event.kind {
            case .sustainedHeat(let celsius):
                deliver(
                    identifier: "macfan.heat",
                    title: "Sustained high temperature",
                    body: "The CPU has stayed at or above \(settings.temperatureUnit.degreesWithUnit(settings.alertThresholdCelsius)) for a minute (now \(settings.temperatureUnit.degreesWithUnit(celsius)))."
                )
            case .controlLost:
                deliver(
                    identifier: "macfan.control-loss",
                    title: "Fan control was released",
                    body: "MacFan lost verified control and every fan returned to macOS Auto. Open MacFan for details."
                )
            }
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func deliver(identifier: String, title: String, body: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(identifier).\(Date.now.timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
