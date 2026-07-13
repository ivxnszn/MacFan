import Combine
import Foundation
import ServiceManagement

enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .celsius: "Celsius (°C)"
        case .fahrenheit: "Fahrenheit (°F)"
        }
    }

    var suffix: String {
        switch self {
        case .celsius: "°C"
        case .fahrenheit: "°F"
        }
    }

    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// "49°" — for compact chrome like the menu bar and gauges.
    func degrees(_ celsius: Double) -> String {
        "\(Int(convert(celsius).rounded()))°"
    }

    /// "49°C" — where the unit matters.
    func degreesWithUnit(_ celsius: Double) -> String {
        "\(Int(convert(celsius).rounded()))\(suffix)"
    }
}

enum MenuBarFormat: String, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case temperature
    case temperatureAndMode
    case temperatureAndRPM

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .temperature: "Temperature — 49°"
        case .temperatureAndMode: "Temperature and mode — 49° · Max"
        case .temperatureAndRPM: "Temperature and fan speed — 49° · 2100"
        }
    }
}

/// How the temperature history renders — the same series, three ways.
enum ThermalChartStyle: String, CaseIterable, Identifiable, Sendable {
    case line
    case area
    case ribbon

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .ribbon: "waveform.path.ecg.rectangle"
        }
    }

    var title: String {
        switch self {
        case .line: "Line"
        case .area: "Area"
        case .ribbon: "Ribbon"
        }
    }
}

/// User preferences persisted in UserDefaults. Everything stays local.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private var suppressLaunchAtLoginSync = false

    @Published var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Keys.temperatureUnit) }
    }
    @Published var menuBarFormat: MenuBarFormat {
        didSet { defaults.set(menuBarFormat.rawValue, forKey: Keys.menuBarFormat) }
    }
    /// Registration happens only when the user flips the toggle — never
    /// silently at launch.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !suppressLaunchAtLoginSync, oldValue != launchAtLogin else { return }
            let service = SMAppService.mainApp
            do {
                if launchAtLogin { try service.register() } else { try service.unregister() }
            } catch {
                suppressLaunchAtLoginSync = true
                launchAtLogin = service.status == .enabled
                suppressLaunchAtLoginSync = false
            }
        }
    }
    @Published var showPopoverFanBank: Bool {
        didSet { defaults.set(showPopoverFanBank, forKey: Keys.showPopoverFanBank) }
    }
    @Published var showPopoverTimeline: Bool {
        didSet { defaults.set(showPopoverTimeline, forKey: Keys.showPopoverTimeline) }
    }
    @Published var showDashboardRPMChart: Bool {
        didSet { defaults.set(showDashboardRPMChart, forKey: Keys.showDashboardRPMChart) }
    }
    @Published var showDashboardInlineInsights: Bool {
        didSet { defaults.set(showDashboardInlineInsights, forKey: Keys.showDashboardInlineInsights) }
    }
    @Published var showDashboardLiveModules: Bool {
        didSet { defaults.set(showDashboardLiveModules, forKey: Keys.showDashboardLiveModules) }
    }
    @Published var showDashboardSupportingAnalytics: Bool {
        didSet { defaults.set(showDashboardSupportingAnalytics, forKey: Keys.showDashboardSupportingAnalytics) }
    }
    @Published var thermalChartStyle: ThermalChartStyle {
        didSet { defaults.set(thermalChartStyle.rawValue, forKey: Keys.thermalChartStyle) }
    }
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Keys.alertsEnabled) }
    }
    @Published var alertThresholdCelsius: Double {
        didSet { defaults.set(alertThresholdCelsius, forKey: Keys.alertThreshold) }
    }
    /// SMC keys the user starred on the Sensors page.
    @Published var pinnedSensorKeys: Set<String> {
        didSet { defaults.set(Array(pinnedSensorKeys).sorted(), forKey: Keys.pinnedSensorKeys) }
    }

    func togglePinned(_ key: String) {
        if pinnedSensorKeys.contains(key) {
            pinnedSensorKeys.remove(key)
        } else if pinnedSensorKeys.count < 2 {
            pinnedSensorKeys.insert(key)
        }
    }

    init(defaults: UserDefaults = .standard, readsLoginItemStatus: Bool = true) {
        self.defaults = defaults
        temperatureUnit = defaults.string(forKey: Keys.temperatureUnit).flatMap(TemperatureUnit.init) ?? .celsius
        menuBarFormat = defaults.string(forKey: Keys.menuBarFormat).flatMap(MenuBarFormat.init) ?? .temperatureAndMode
        launchAtLogin = readsLoginItemStatus && SMAppService.mainApp.status == .enabled
        showPopoverFanBank = defaults.object(forKey: Keys.showPopoverFanBank) as? Bool ?? true
        showPopoverTimeline = defaults.object(forKey: Keys.showPopoverTimeline) as? Bool ?? true
        showDashboardRPMChart = defaults.object(forKey: Keys.showDashboardRPMChart) as? Bool ?? true
        showDashboardInlineInsights = defaults.object(forKey: Keys.showDashboardInlineInsights) as? Bool ?? true
        showDashboardLiveModules = defaults.object(forKey: Keys.showDashboardLiveModules) as? Bool ?? true
        showDashboardSupportingAnalytics = defaults.object(forKey: Keys.showDashboardSupportingAnalytics) as? Bool ?? true
        thermalChartStyle = defaults.string(forKey: Keys.thermalChartStyle).flatMap(ThermalChartStyle.init) ?? .area
        alertsEnabled = defaults.bool(forKey: Keys.alertsEnabled)
        let threshold = defaults.double(forKey: Keys.alertThreshold)
        alertThresholdCelsius = threshold == 0 ? 85 : min(max(threshold, 70), 100)
        // Older builds allowed an unbounded comparison set. Migrate it to the
        // current two-sensor contract deterministically so the chart never
        // opens with an overloaded or order-dependent legend.
        pinnedSensorKeys = Set((defaults.stringArray(forKey: Keys.pinnedSensorKeys) ?? []).sorted().prefix(2))
    }

    private enum Keys {
        static let temperatureUnit = "macfan.temperatureUnit"
        static let menuBarFormat = "macfan.menuBarFormat"
        static let showPopoverFanBank = "macfan.popover.fanBank"
        static let showPopoverTimeline = "macfan.popover.timeline"
        static let showDashboardRPMChart = "macfan.dashboard.rpmChart"
        static let showDashboardInlineInsights = "macfan.dashboard.inlineInsights"
        static let showDashboardLiveModules = "macfan.dashboard.liveModules"
        static let showDashboardSupportingAnalytics = "macfan.dashboard.supportingAnalytics"
        static let thermalChartStyle = "macfan.dashboard.thermalChartStyle"
        static let alertsEnabled = "macfan.alerts.enabled"
        static let pinnedSensorKeys = "macfan.sensors.pinned"
        static let alertThreshold = "macfan.alerts.thresholdCelsius"
    }
}
