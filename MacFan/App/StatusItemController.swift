import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let settings: AppSettings
    private let onShowDashboard: (DashboardTab?) -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private var lastStatusTitle = ""
    private var lastCapability: ControlCapability?

    init(model: AppModel, settings: AppSettings, onShowDashboard: @escaping (DashboardTab?) -> Void) {
        self.model = model
        self.settings = settings
        self.onShowDashboard = onShowDashboard
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        observeModel()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if NSEvent.modifierFlags.contains(.option) {
            model.startCoolBurst()
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.image = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: "MacFan")?.withSymbolConfiguration(configuration)
        button.imagePosition = .imageLeft
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "MacFan — Option-click for a 10-minute Cool Burst after verified experimental control is enabled"
        button.setAccessibilityLabel("MacFan thermal status")
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        // Sized for glanceability while keeping the primary actions above the fold.
        popover.contentSize = NSSize(width: 388, height: 520)
        popover.delegate = self
    }

    private func makePopoverContent() -> NSViewController {
        NSHostingController(
            rootView: PopoverView(onShowDashboard: { [weak self] tab in
                self?.popover.performClose(nil)
                self?.onShowDashboard(tab)
            }, onShowSettings: { [weak self] in
                self?.popover.performClose(nil)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }, onQuit: { [weak self] in
                self?.popover.performClose(nil)
                NSApp.terminate(nil)
            }).environmentObject(model).environmentObject(settings)
        )
    }

    private func observeModel() {
        Publishers.CombineLatest3(model.$snapshot, model.$capability, model.$activeMode)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.renderStatusItem() }
            .store(in: &subscriptions)
        // Unit/format preference changes re-render with the current telemetry.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.renderStatusItem() }
            .store(in: &subscriptions)
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let snapshot = model.snapshot
        let mode = model.activeMode
        let capability = model.capability
        let temperature = snapshot.displayTemperature.map { settings.temperatureUnit.degrees($0.celsius) } ?? "—"
        let title: String
        switch settings.menuBarFormat {
        case .iconOnly:
            title = ""
        case .temperature:
            title = " \(temperature)"
        case .temperatureAndMode:
            title = mode == .system ? " \(temperature)" : " \(temperature) · \(mode.uiTitle.uppercased())"
        case .temperatureAndRPM:
            let fans = snapshot.fans
            let rpm = fans.isEmpty ? "—" : "\(Int((fans.map(\.actualRPM).reduce(0, +) / Double(fans.count)).rounded()))"
            title = " \(temperature) · \(rpm)"
        }
        // The rounded degree rarely changes between ticks; skip the
        // status-bar redraw when nothing the user can see moved.
        guard title != lastStatusTitle || capability != lastCapability else { return }
        lastStatusTitle = title
        lastCapability = capability
        button.title = title
        button.toolTip = "MacFan · \(mode.uiTitle) · \(capability.title) (\(capability.shortReason)) · Option-click for Cool Burst (needs control)"
        button.setAccessibilityValue("\(temperature), \(mode.uiTitle) mode, \(capability.title)")
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Built on demand and torn down on close, so the SwiftUI hierarchy
        // does not keep re-rendering on telemetry ticks while hidden.
        if popover.contentViewController == nil {
            popover.contentViewController = makePopoverContent()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.surfaceDidShow(.popover)
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        model.surfaceDidHide(.popover)
    }
}
