import Foundation

enum MacFanHelperConstants {
    static let machServiceName = "local.macfan.helper"
    static let helperPath = "/Library/PrivilegedHelperTools/local.macfan.helper"
    static let launchDaemonPath = "/Library/LaunchDaemons/local.macfan.helper.plist"
    static let configurationPath = "/Library/Application Support/MacFan/helper-config.plist"
    static let appBundleIdentifier = "local.macfan"
    static let protocolVersion = 1

    static let competingControllerPaths = [
        "/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite",
        "/Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist"
    ]
}

/// Deliberately narrow root-helper surface. It exposes no SMC key, byte,
/// filesystem, process, or shell-command primitive.
@objc protocol MacFanControlXPC {
    func capabilities(
        with reply: @escaping (
            Bool, Bool, [NSNumber], [NSNumber], [NSNumber], [NSNumber], String
        ) -> Void
    )

    func preflight(with reply: @escaping (Bool, String) -> Void)

    /// Supported modes are `max` and `manual`. Manual requests must contain
    /// exactly one entry for every helper-discovered fan. Max accepts no
    /// client targets and uses helper-discovered maxima.
    func setMode(
        _ mode: String,
        fanIDs: [NSNumber],
        rpms: [NSNumber],
        reply: @escaping (Bool, [NSNumber], [NSNumber], String) -> Void
    )

    func restoreSystem(with reply: @escaping (Bool, String) -> Void)
    func heartbeat(with reply: @escaping (Bool) -> Void)
}
