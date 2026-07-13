import Foundation
import IOKit
import OSLog

private let hardwareLog = Logger(subsystem: "local.macfan.helper", category: "hardware")

enum HelperSMCError: Error, LocalizedError {
    case notRoot
    case connectionFailed
    case ioKit(kern_return_t)
    case invalidWireLayout(Int)
    case invalidKey(String)
    case invalidPayload(String)
    case firmware(key: String, result: UInt8)
    case noFans
    case unsafeFanLimits(Int)
    case temperatureUnavailable
    case preflightTooHot(Double)
    case unsupportedHardware
    case unlockTimedOut
    case responseNotConfirmed
    case restoreNotConfirmed

    var errorDescription: String? {
        switch self {
        case .notRoot:
            "The MacFan helper must run as root."
        case .connectionFailed:
            "The Apple SMC service could not be opened."
        case .ioKit(let code):
            "Apple SMC IOKit error 0x\(String(code, radix: 16))."
        case .invalidWireLayout(let size):
            "The Apple SMC wire structure is \(size) bytes instead of 80."
        case .invalidKey(let key):
            "The Apple SMC key \(key) is invalid."
        case .invalidPayload(let key):
            "The Apple SMC value for \(key) has an unsupported format."
        case .firmware(let key, let result):
            "Apple firmware rejected \(key) (0x\(String(result, radix: 16)))."
        case .noFans:
            "No controllable fans were discovered."
        case .unsafeFanLimits(let id):
            "Fan \(id) reported unsafe hardware limits."
        case .temperatureUnavailable:
            "No trustworthy CPU/GPU temperature telemetry is available."
        case .preflightTooHot(let temperature):
            "Preflight is disabled while the Mac is hot (\(Int(temperature.rounded()))°C)."
        case .unsupportedHardware:
            "This Apple SMC revision does not expose a supported fan mode key."
        case .unlockTimedOut:
            "Apple thermal control did not yield manual fan mode in time."
        case .responseNotConfirmed:
            "The requested fan response could not be physically confirmed."
        case .restoreNotConfirmed:
            "The helper could not confirm that macOS regained fan control."
        }
    }
}

private final class HelperSMCConnection {
    private enum Command: UInt8 {
        case kernelIndex = 2
        case readBytes = 5
        case writeBytes = 6
        case readKeyInfo = 9
    }

    private typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfoWire {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var attributes: UInt8 = 0
    }

    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var pLimit = PLimitData()
        var keyInfo = KeyInfoWire()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    struct KeyInfo {
        let size: UInt32
        let type: String
    }

    private let connection: io_connect_t

    init() throws {
        guard geteuid() == 0 else { throw HelperSMCError.notRoot }
        let wireSize = MemoryLayout<Param>.stride
        guard wireSize == 80 else { throw HelperSMCError.invalidWireLayout(wireSize) }

        var iterator: io_iterator_t = 0
        var foundService: io_service_t = 0
        for matchingName in ["AppleSMC", "AppleSMCKeysEndpoint"] {
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(matchingName),
                &iterator
            ) == kIOReturnSuccess else { continue }
            let service = IOIteratorNext(iterator)
            IOObjectRelease(iterator)
            iterator = 0
            if service != 0 {
                foundService = service
                break
            }
        }

        guard foundService != 0 else { throw HelperSMCError.connectionFailed }
        defer { IOObjectRelease(foundService) }
        var opened: io_connect_t = 0
        let result = IOServiceOpen(foundService, mach_task_self_, 0, &opened)
        guard result == kIOReturnSuccess else { throw HelperSMCError.ioKit(result) }
        connection = opened
    }

    deinit { IOServiceClose(connection) }

    func keyInfo(_ key: String) throws -> KeyInfo {
        var input = Param()
        input.key = try fourCharacterCode(key)
        input.data8 = Command.readKeyInfo.rawValue
        let output = try call(input)
        guard output.result == 0 else {
            throw HelperSMCError.firmware(key: key, result: output.result)
        }
        guard output.keyInfo.dataSize > 0, output.keyInfo.dataSize <= 32 else {
            throw HelperSMCError.invalidPayload(key)
        }
        var type = output.keyInfo.dataType.bigEndian
        let typeString = withUnsafeBytes(of: &type) {
            String(bytes: $0, encoding: .ascii) ?? "????"
        }
        return KeyInfo(size: output.keyInfo.dataSize, type: typeString)
    }

    func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func read(_ key: String) throws -> (bytes: [UInt8], info: KeyInfo) {
        let info = try keyInfo(key)
        var input = Param()
        input.key = try fourCharacterCode(key)
        input.keyInfo.dataSize = info.size
        input.data8 = Command.readBytes.rawValue
        let output = try call(input)
        guard output.result == 0 else {
            throw HelperSMCError.firmware(key: key, result: output.result)
        }
        return (withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }, info)
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == Int(info.size) else { throw HelperSMCError.invalidPayload(key) }
        var input = Param()
        input.key = try fourCharacterCode(key)
        input.keyInfo.dataSize = info.size
        input.data8 = Command.writeBytes.rawValue
        input.bytes = tuple(bytes)
        let output = try call(input)
        guard output.result == 0 else {
            throw HelperSMCError.firmware(key: key, result: output.result)
        }
    }

    func readUInt8(_ key: String) throws -> UInt8 {
        guard let first = try read(key).bytes.first else { throw HelperSMCError.invalidPayload(key) }
        return first
    }

    func writeUInt8(_ key: String, _ value: UInt8) throws {
        let info = try keyInfo(key)
        guard info.size == 1 else { throw HelperSMCError.invalidPayload(key) }
        try write(key, bytes: [value])
    }

    func readRPM(_ key: String) throws -> Double {
        let value = try read(key)
        switch value.info.size {
        case 4:
            guard value.bytes.count >= 4 else { throw HelperSMCError.invalidPayload(key) }
            let bits = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Double(Float(bitPattern: bits))
        case 2:
            guard value.bytes.count >= 2 else { throw HelperSMCError.invalidPayload(key) }
            let raw = value.bytes.withUnsafeBytes {
                UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
            }
            return Double(raw) / 4
        default:
            throw HelperSMCError.invalidPayload(key)
        }
    }

    func readTemperature(_ key: String) throws -> Double {
        let value = try read(key)
        switch value.info.type {
        case "sp78":
            guard value.bytes.count >= 2 else { throw HelperSMCError.invalidPayload(key) }
            let raw = value.bytes.withUnsafeBytes {
                UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
            }
            return Double(Int16(bitPattern: raw)) / 256
        case "flt ", "flt":
            guard value.bytes.count >= 4 else { throw HelperSMCError.invalidPayload(key) }
            let bits = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Double(Float(bitPattern: bits))
        default:
            throw HelperSMCError.invalidPayload(key)
        }
    }

    func writeRPM(_ key: String, _ rpm: Double) throws {
        guard rpm.isFinite, rpm >= 0 else { throw HelperSMCError.invalidPayload(key) }
        let info = try keyInfo(key)
        let bytes: [UInt8]
        switch info.size {
        case 4:
            var value = Float(rpm).bitPattern
            bytes = withUnsafeBytes(of: &value) { Array($0) }
        case 2:
            var value = UInt16(min(rpm * 4, Double(UInt16.max))).bigEndian
            bytes = withUnsafeBytes(of: &value) { Array($0) }
        default:
            throw HelperSMCError.invalidPayload(key)
        }
        try write(key, bytes: bytes)
    }

    private func call(_ source: Param) throws -> Param {
        var input = source
        var output = Param()
        var outputSize = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(
            connection,
            UInt32(Command.kernelIndex.rawValue),
            &input,
            MemoryLayout<Param>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else { throw HelperSMCError.ioKit(result) }
        guard outputSize == MemoryLayout<Param>.stride else {
            throw HelperSMCError.invalidWireLayout(outputSize)
        }
        return output
    }

    private func fourCharacterCode(_ string: String) throws -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { throw HelperSMCError.invalidKey(string) }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func tuple(_ source: [UInt8]) -> Bytes32 {
        let bytes = source + Array(repeating: 0, count: 32 - source.count)
        return (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
            bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23],
            bytes[24], bytes[25], bytes[26], bytes[27], bytes[28], bytes[29], bytes[30], bytes[31]
        )
    }
}

struct HelperFanState: Sendable {
    let limit: HelperFanLimit
    let actualRPM: Double
    let targetRPM: Double
    let isManual: Bool
}

/// The only type in the helper that knows SMC fan keys. The XPC service hands
/// it validated semantic requests, never keys or bytes.
final class SMCFanHardwareController {
    private let connection: HelperSMCConnection
    let limits: [HelperFanLimit]
    private let modeKeySuffix: String
    private let forceTestAvailable: Bool
    private let temperatureKeys: [String]

    init() throws {
        let connection = try HelperSMCConnection()
        let count = Int(try connection.readUInt8("FNum"))
        guard (1...8).contains(count) else { throw HelperSMCError.noFans }

        let modeSuffix: String
        if connection.keyExists("F0Md") {
            modeSuffix = "Md"
        } else if connection.keyExists("F0md") {
            modeSuffix = "md"
        } else {
            throw HelperSMCError.unsupportedHardware
        }

        var discovered: [HelperFanLimit] = []
        for id in 0..<count {
            let minimum = try connection.readRPM("F\(id)Mn")
            let maximum = try connection.readRPM("F\(id)Mx")
            let limit = HelperFanLimit(id: id, minimumRPM: minimum, maximumRPM: maximum)
            guard limit.isValid else { throw HelperSMCError.unsafeFanLimits(id) }
            guard connection.keyExists("F\(id)\(modeSuffix)"), connection.keyExists("F\(id)Tg") else {
                throw HelperSMCError.unsupportedHardware
            }
            discovered.append(limit)
        }

        self.connection = connection
        limits = discovered
        modeKeySuffix = modeSuffix
        forceTestAvailable = connection.keyExists("Ftst")
        let preferredTemperatureKeys = [
            "TCMz", "TCMb", "TRDX",
            "Tp0P", "Tp0T", "Tp1T", "Tp2T", "Tp3T", "Tp4T",
            "TC0P", "TC0E", "TC0F", "TC0D", "TG0P", "TG0D", "TG0T"
        ]
        temperatureKeys = preferredTemperatureKeys.filter { key in
            guard let info = try? connection.keyInfo(key) else { return false }
            return info.type == "sp78" || info.type == "flt " || info.type == "flt"
        }
        guard !temperatureKeys.isEmpty else { throw HelperSMCError.temperatureUnavailable }
    }

    func states() throws -> [HelperFanState] {
        try limits.map { limit in
            let actual = try connection.readRPM(actualKey(limit.id))
            let target = try connection.readRPM(targetKey(limit.id))
            guard actual.isFinite, target.isFinite,
                  actual >= 0, actual <= 20_000,
                  target >= 0, target <= 20_000 else {
                throw HelperSMCError.invalidPayload(actualKey(limit.id))
            }
            return HelperFanState(
                limit: limit,
                actualRPM: actual,
                targetRPM: target,
                isManual: try connection.readUInt8(modeKey(limit.id)) == 1
            )
        }
    }

    func hottestTemperature() throws -> Double {
        let values = temperatureKeys.compactMap { key -> Double? in
            guard let value = try? connection.readTemperature(key),
                  value.isFinite, (-10...130).contains(value) else { return nil }
            return value
        }
        guard let hottest = values.max() else { throw HelperSMCError.temperatureUnavailable }
        return hottest
    }

    func targetsForMaximum() -> [Int: Double] {
        Dictionary(uniqueKeysWithValues: limits.map { ($0.id, $0.maximumRPM) })
    }

    func apply(targets: [Int: Double]) throws {
        let ids = targets.keys.sorted()
        let safe = try FanTargetValidator.validate(
            expected: limits,
            fanIDs: ids,
            rpms: ids.compactMap { targets[$0] }
        )

        do {
            try enableManualMode()
            for limit in limits {
                guard let rpm = safe[limit.id] else { throw FanTargetValidationError.missingFanIDs([limit.id]) }
                try writeTarget(rpm, fanID: limit.id)
            }
            try verifyManualTargets(safe)
        } catch {
            _ = restoreSystem()
            throw error
        }
    }

    /// Briefly requests maximum cooling, proves the physical fan response, and
    /// only succeeds after Auto/System has also been read back.
    func preflight(timeout: TimeInterval = 15) throws {
        let temperature = try hottestTemperature()
        guard temperature < 80 else { throw HelperSMCError.preflightTooHot(temperature) }
        let before = try states()
        let targets = targetsForMaximum()
        do {
            try apply(targets: targets)
            let deadline = Date().addingTimeInterval(min(max(timeout, 4), 20))
            var confirmed = false
            var lastObserved = before
            repeat {
                let after = try states()
                lastObserved = after
                confirmed = zip(before, after).allSatisfy { initial, current in
                    guard let target = targets[current.limit.id] else { return false }
                    return current.isManual && PreflightResponseVerifier.confirmed(
                        before: initial.actualRPM,
                        after: current.actualRPM,
                        target: target,
                        targetReadback: current.targetRPM,
                        limit: current.limit
                    )
                }
                if !confirmed { wait(0.5) }
            } while !confirmed && Date() < deadline

            guard confirmed else {
                let summary = lastObserved.map {
                    "fan\($0.limit.id): actual=\(Int($0.actualRPM.rounded())) target=\(Int($0.targetRPM.rounded())) manual=\($0.isManual)"
                }.joined(separator: ", ")
                hardwareLog.error("preflight response timeout: \(summary, privacy: .public)")
                throw HelperSMCError.responseNotConfirmed
            }
            guard restoreSystem() else { throw HelperSMCError.restoreNotConfirmed }
        } catch {
            _ = restoreSystem()
            throw error
        }
    }

    /// Best-effort release. It deliberately tries every fan and Ftst even if
    /// an earlier write fails, then verifies that no fan remains manual.
    @discardableResult
    func restoreSystem() -> Bool {
        for limit in limits {
            try? connection.writeUInt8(modeKey(limit.id), 0)
            try? connection.writeRPM(targetKey(limit.id), 0)
        }
        if forceTestAvailable { try? connection.writeUInt8("Ftst", 0) }

        let deadline = Date().addingTimeInterval(5)
        var lastConfirmed = false
        repeat {
            let noManualFan = limits.allSatisfy { limit in
                guard let mode = try? connection.readUInt8(modeKey(limit.id)) else { return false }
                return mode != 1
            }
            let forceTestReleased = !forceTestAvailable || (try? connection.readUInt8("Ftst")) == 0
            lastConfirmed = noManualFan && forceTestReleased
            if lastConfirmed { return true }
            guard Date() < deadline else { break }
            wait(0.1)
        } while true
        return lastConfirmed
    }

    private func enableManualMode(timeout: TimeInterval = 10) throws {
        // M3/M4 firmware can acknowledge a direct mode write and expose mode 1
        // for a moment while thermalmonitord is already reclaiming it. Treating
        // that transient readback as success makes the following target write
        // ineffective. When Ftst exists, assert it first and keep it asserted
        // for the entire override lease. Newer revisions without Ftst use the
        // direct mode path.
        if forceTestAvailable {
            try connection.writeUInt8("Ftst", 1)
            wait(0.5)
        } else {
            for limit in limits { try connection.writeUInt8(modeKey(limit.id), 1) }
            guard allFansManual() else { throw HelperSMCError.unsupportedHardware }
            return
        }

        let deadline = Date().addingTimeInterval(min(max(timeout, 2), 12))
        repeat {
            for limit in limits { try? connection.writeUInt8(modeKey(limit.id), 1) }
            if allFansManual() { return }
            wait(0.1)
        } while Date() < deadline
        throw HelperSMCError.unlockTimedOut
    }

    private func allFansManual() -> Bool {
        limits.allSatisfy { (try? connection.readUInt8(modeKey($0.id))) == 1 }
    }

    private func writeTarget(_ rpm: Double, fanID: Int) throws {
        let key = targetKey(fanID)
        let deadline = Date().addingTimeInterval(2)
        var readback = try connection.readRPM(key)
        repeat {
            if forceTestAvailable, (try? connection.readUInt8("Ftst")) != 1 {
                try connection.writeUInt8("Ftst", 1)
            }
            if (try? connection.readUInt8(modeKey(fanID))) != 1 {
                try connection.writeUInt8(modeKey(fanID), 1)
            }
            do {
                try connection.writeRPM(key, rpm)
            } catch HelperSMCError.firmware(_, 0x87) {
                // Some Apple SMC revisions apply F#Tg while returning
                // sizeMismatch. Readback is authoritative.
            }
            readback = try connection.readRPM(key)
            if abs(readback - rpm) <= max(60, rpm * 0.015) { return }
            wait(0.1)
        } while Date() < deadline

        let mode = (try? connection.readUInt8(modeKey(fanID))) ?? 255
        let ftst = forceTestAvailable ? ((try? connection.readUInt8("Ftst")) ?? 255) : 254
        hardwareLog.error("target readback mismatch fan=\(fanID) requested=\(rpm) readback=\(readback) mode=\(mode) ftst=\(ftst)")
        throw HelperSMCError.responseNotConfirmed
    }

    private func verifyManualTargets(_ targets: [Int: Double]) throws {
        for limit in limits {
            guard try connection.readUInt8(modeKey(limit.id)) == 1,
                  let target = targets[limit.id] else {
                throw HelperSMCError.responseNotConfirmed
            }
            let readback = try connection.readRPM(targetKey(limit.id))
            guard abs(readback - target) <= max(60, target * 0.015) else {
                throw HelperSMCError.responseNotConfirmed
            }
        }
    }

    /// Lightweight periodic reassertion for sustained overrides (e.g. Max mode).
    /// Re-writes Ftst/mode/target without confirmation loops or waits so the
    /// helper can fight macOS reclamation between heartbeats. Watchdog still
    /// validates; this just improves the chance the desired state sticks.
    /// For Max/full-blast we double-tap the writes as macOS thermal can race the
    /// first set when fans were at 0.
    func reassert(targets: [Int: Double]) {
        guard !targets.isEmpty else { return }
        if forceTestAvailable {
            try? connection.writeUInt8("Ftst", 1)
            try? connection.writeUInt8("Ftst", 1)
        }
        for limit in limits {
            guard let rpm = targets[limit.id] else { continue }
            try? connection.writeUInt8(modeKey(limit.id), 1)
            try? connection.writeRPM(targetKey(limit.id), rpm)
            // Double write to increase chance of sticking against reclaim on M-series.
            try? connection.writeUInt8(modeKey(limit.id), 1)
            try? connection.writeRPM(targetKey(limit.id), rpm)
        }
    }

    private func actualKey(_ id: Int) -> String { "F\(id)Ac" }
    private func targetKey(_ id: Int) -> String { "F\(id)Tg" }
    private func modeKey(_ id: Int) -> String { "F\(id)\(modeKeySuffix)" }

    // Lightweight wait that offloads the timer to a global queue.
    // Reduces pressure on the serial control queue compared to direct Thread.sleep
    // during hardware confirmation loops (preflight/write).
    private func wait(_ seconds: TimeInterval) {
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            sem.signal()
        }
        sem.wait()
    }
}
