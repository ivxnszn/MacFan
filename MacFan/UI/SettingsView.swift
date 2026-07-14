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
                // Prominent, scannable status with clear state, why, meaning, and fix.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: model.capability.statusIcon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(model.capability.canControl ? Color.macFanMint : Color.macFanAmberLight)
                            .frame(width: 24, height: 24)
                            .background((model.capability.canControl ? Color.macFanMint : Color.macFanAmberLight).opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(model.capability.title)
                                    .macFanSubhead()
                                    .foregroundStyle(Color.macFanPrimary)
                                if !model.capability.canControl && !model.capability.monitorLabel.isEmpty {
                                    Text(model.capability.monitorLabel)
                                        .macFanCaption()
                                        .foregroundStyle(Color.macFanAmberLight)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.macFanAmberLight.opacity(0.15), in: Capsule())
                                }
                            }
                            Text(model.capability.shortReason)
                                .macFanCaption()
                                .foregroundStyle(Color.macFanSecondary)
                        }

                        Spacer()

                        if model.capability.canControl {
                            Label("Full control", systemImage: "checkmark.circle.fill")
                                .macFanCaption()
                                .foregroundStyle(Color.macFanMint)
                        } else {
                            Text("Monitoring only")
                                .macFanCaption()
                                .foregroundStyle(Color.macFanAmberLight)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.macFanAmberLight.opacity(0.12), in: Capsule())
                                .overlay(Capsule().stroke(Color.macFanAmberLight.opacity(0.3), lineWidth: 0.5))
                        }
                    }
                    .help("Current control capability. Ready = you can change fan behavior. Otherwise MacFan is monitor-only.")

                    // WHY
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Why")
                            .macFanSectionLabel()
                            .foregroundStyle(Color.macFanMuted)
                        Text(model.capability.whyMessage.isEmpty ? "Control is fully available." : model.capability.whyMessage)
                            .macFanCallout()
                            .foregroundStyle(Color.macFanPrimary)
                    }

                    // WHAT IT MEANS
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What this means")
                            .macFanSectionLabel()
                            .foregroundStyle(Color.macFanMuted)
                        Text(model.capability.whatItMeans)
                            .macFanCallout()
                            .foregroundStyle(Color.macFanPrimary)
                    }

                    // HOW TO FIX (only when limited)
                    if model.capability.isMonitoringOnly {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("How to enable control")
                                .macFanSectionLabel()
                                .foregroundStyle(Color.macFanMuted)
                            Text(model.capability.howToFix)
                                .macFanCallout()
                                .foregroundStyle(Color.macFanPrimary)
                        }
                    } else {
                        Text("Helper verified. Fan tweaks (Smart, Max, Expert, Cool Burst) are enabled. Safety restore on quit or loss of connection.")
                            .macFanCallout()
                            .foregroundStyle(Color.macFanSecondary)
                    }
                }
                .padding(.vertical, 4)
                .help("Status explains the control state: why you are (or are not) limited to monitoring, what that restricts, and the exact fix.")

                HStack(spacing: 8) {
                    Button {
                        model.forceCapabilityRefresh()
                    } label: {
                        Label("Check status now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Immediately re-probe the helper and preflight. Use after installing the helper or removing a competing controller.")

                    Button {
                        if !ControlSetupLauncher.openInstallerInTerminal() {
                            showMissingInstallerAlert = true
                        }
                    } label: {
                        Label(model.capability.actionLabel, systemImage: "wrench.and.screwdriver")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.macFanBlue)
                    .help("Opens Terminal with the local installer script. It builds and installs the narrow root helper that allows fan speed changes. Requires admin password once. This is required to exit monitor-only mode.")
                }
                .padding(.top, 6)
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
