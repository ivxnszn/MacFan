import AppKit
import Combine
import SwiftUI

/// One global listener so arrival haptics fire exactly once per state change,
/// no matter which surfaces are open. Button styles tick on press; this
/// thunks only when the hardware actually confirms.
@MainActor
final class FeedbackCoordinator {
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel) {
        model.$activeMode
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in MacFanHaptics.success() }
            .store(in: &subscriptions)
        model.$capability
            .map(\.canControl)
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { _ in MacFanHaptics.success() }
            .store(in: &subscriptions)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let settings = AppSettings()
    private var statusController: StatusItemController?
    private var dashboardController: DashboardWindowController?
    private var fixturePopoverWindow: NSWindow?
    private var alertCoordinator: AlertCoordinator?
    private var feedbackCoordinator: FeedbackCoordinator?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var isCoordinatingTermination = false
    private var hasRepliedToTermination = false
    private var terminationRestoreTask: Task<Void, Never>?
    private var terminationDeadlineTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        dashboardController = DashboardWindowController(model: model, settings: settings)
        statusController = StatusItemController(model: model, settings: settings) { [weak self] in
            self?.dashboardController?.show()
        }
        observeSleepWake()
        observeDashboardVisibility()
        // UI fixtures must be deterministic even when a developer's normal
        // preferences have the optional popover modules hidden.
        if ProcessInfo.processInfo.environment["MACFAN_UI_TEST_MODE"] == "1" {
            settings.showPopoverFanBank = true
            settings.showPopoverTimeline = true
        }
        if ProcessInfo.processInfo.environment["MACFAN_UI_TEST_MODE"] != "1" {
            alertCoordinator = AlertCoordinator(model: model, settings: settings)
            feedbackCoordinator = FeedbackCoordinator(model: model)
        }
        model.start()
        // Auto-show the full dashboard on normal launch so the user can immediately see the Overview tab changes when double-clicking the app in Applications.
        // The app remains primarily menu-bar driven (popover for quick access), but opening the app brings up the rich dashboard.
        dashboardController?.show()
        if ProcessInfo.processInfo.environment["MACFAN_UI_TEST_MODE"] == "1" {
            if ProcessInfo.processInfo.environment["MACFAN_UI_TEST_POPOVER"] == "1" {
                showPopoverFixture()
            } else {
                dashboardController?.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !isCoordinatingTermination { model.stop() }
        terminationRestoreTask?.cancel()
        terminationDeadlineTask?.cancel()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.removeAll()
        windowObservers.removeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isCoordinatingTermination else { return .terminateLater }
        isCoordinatingTermination = true
        hasRepliedToTermination = false

        // Ask the helper to restore System before allowing the process to exit.
        // XPC continuations cannot always be cancelled while a firmware
        // preflight is in flight, so keep the app responsive with a firm
        // deadline. If that deadline wins, the helper's independent heartbeat
        // lease still releases every fan when this process disappears.
        terminationRestoreTask = Task { @MainActor [weak self, weak sender] in
            guard let self else {
                sender?.reply(toApplicationShouldTerminate: true)
                return
            }
            await model.stopAndRestore()
            finishTermination(sender)
        }
        terminationDeadlineTask = Task { @MainActor [weak self, weak sender] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication?) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        terminationRestoreTask?.cancel()
        terminationDeadlineTask?.cancel()
        sender?.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dashboardController?.show()
        return true
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.model.handleSleep()
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.model.handleWake() }
            }
        )
    }

    /// `NSWindowDelegate.windowWillClose` is not called when a window is
    /// minimized or fully occluded. Track those transitions without replacing
    /// DashboardWindowController's delegate, so adaptive polling and page-level
    /// samplers can pause while preserving every transient SwiftUI selection.
    private func observeDashboardVisibility() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification
        ]
        for name in names {
            windowObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let window = notification.object as? NSWindow,
                          window.title == "MacFan — Thermal History" else { return }
                    Task { @MainActor [weak self, weak window] in
                        guard let self, let window else { return }
                        let isActuallyVisible = window.isVisible
                            && !window.isMiniaturized
                            && window.occlusionState.contains(.visible)
                        model.setSurface(.dashboard, visible: isActuallyVisible)
                    }
                }
            )
        }
    }

    /// A regular host window for deterministic visual and accessibility QA of
    /// the otherwise transient menu-bar popover. It is reachable only in the
    /// isolated UI-test fixture process; production still uses `NSPopover`.
    private func showPopoverFixture() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 388, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacFan — Popover Preview"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PopoverView(
                onShowDashboard: { [weak self] in
                    self?.fixturePopoverWindow?.orderOut(nil)
                    self?.dashboardController?.show()
                },
                onShowSettings: {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                },
                onQuit: { NSApp.terminate(nil) }
            )
            .environmentObject(model)
            .environmentObject(settings)
        )
        fixturePopoverWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.surfaceDidShow(.popover)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === fixturePopoverWindow else { return }
        fixturePopoverWindow = nil
        model.surfaceDidHide(.popover)
    }
}

@main
struct MacFanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.settings)
        }
    }
}
