import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showClearHistoryConfirmation = false
    @State private var showMissingInstallerAlert = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch MacFan at login", isOn: $settings.launchAtLogin)
                Picker("Temperature unit", selection: $settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
            }
            Section("Fan control") {
                LabeledContent("Status") { Text(model.capability.title) }
                Text(model.capability.canControl
                     ? "The private helper passed hardware preflight. Auto remains available at all times and quitting MacFan releases control."
                     : "Monitoring works normally. Install or repair the private helper to enable Smart, Max, and Manual modes on this Mac.")
                    .macFanCaption()
                    .foregroundStyle(.secondary)
                Button {
                    if !ControlSetupLauncher.openInstallerInTerminal() {
                        showMissingInstallerAlert = true
                    }
                } label: {
                    Label(
                        model.capability.canControl ? "Repair or reinstall control…" : "Install or repair control…",
                        systemImage: "wrench.and.screwdriver"
                    )
                }
                .help("Opens MacFan's local installer in Terminal. macOS asks for your administrator password once.")
            }
            Section("Menu bar") {
                Picker("Menu bar shows", selection: $settings.menuBarFormat) {
                    ForEach(MenuBarFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
            }
            Section("Popover") {
                Toggle("Show live fan speeds", isOn: $settings.showPopoverFanBank)
                Toggle("Show 90-minute heat curve", isOn: $settings.showPopoverTimeline)
            }
            Section("Dashboard") {
                Toggle("Show fan response chart", isOn: $settings.showDashboardRPMChart)
                Toggle("Show inline insights", isOn: $settings.showDashboardInlineInsights)
                Toggle("Show supporting analytics", isOn: $settings.showDashboardSupportingAnalytics)
                Text("Choose how much supporting context appears on Overview. Core temperature and cooling controls always remain visible.")
                    .macFanCaption()
                    .foregroundStyle(.secondary)
            }
            Section("Alerts") {
                Toggle("Notify on sustained high temperature", isOn: $settings.alertsEnabled)
                if settings.alertsEnabled {
                    LabeledContent("Threshold") {
                        Text(settings.temperatureUnit.degreesWithUnit(settings.alertThresholdCelsius))
                            .monospacedDigit()
                    }
                    Slider(value: $settings.alertThresholdCelsius, in: 70...100, step: 1)
                    Text("Fires after the CPU stays above the threshold for a minute, at most once every 15 minutes. Control-loss failures always notify.")
                        .macFanCaption()
                        .foregroundStyle(.secondary)
                }
            }
            Section("History") {
                LabeledContent("Retention") { Text("Raw 24 h · 1-min 7 d · 5-min 30 d") }
                LabeledContent("Storage") { Text("Local SQLite — never leaves this Mac") }
                Button("Clear local history", role: .destructive) { showClearHistoryConfirmation = true }
            }
            Section("Safety") {
                Text("Fan writes use MacFan’s restricted, root-owned local helper and remain disabled until hardware preflight succeeds. Quitting MacFan or losing its heartbeat restores Auto.")
                    .macFanCaption()
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .preferredColorScheme(.dark)
        .confirmationDialog("Clear all local history?", isPresented: $showClearHistoryConfirmation, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
            Button("Keep history", role: .cancel) { }
        } message: {
            Text("This permanently removes MacFan’s local thermal samples and rollups.")
        }
        .alert("MacFan installer not found", isPresented: $showMissingInstallerAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Keep the MacFan source folder in ~/Documents/MacFan, then open Settings again. The expected installer is Scripts/install-local.sh.")
        }
    }
}

/// This product is private to this Mac, so setup deliberately opens the local,
/// reviewable installer instead of downloading code or silently escalating.
/// Terminal presents the administrator-password prompt and keeps the complete
/// install/repair log visible to the owner.
private enum ControlSetupLauncher {
    static func openInstallerInTerminal() -> Bool {
        guard let installer = installerURL else { return false }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: terminal.path) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([installer], withApplicationAt: terminal, configuration: configuration)
        return true
    }

    private static var installerURL: URL? {
        let fileManager = FileManager.default
        var roots: [URL] = []
        if let override = ProcessInfo.processInfo.environment["MACFAN_SOURCE_ROOT"], !override.isEmpty {
            roots.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        roots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
        roots.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents/MacFan", isDirectory: true))
        return roots
            .map { $0.appendingPathComponent("Scripts/install-local.sh", isDirectory: false) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }
}
