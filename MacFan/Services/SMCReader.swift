import Foundation
import IOKit

protocol ThermalTelemetryProviding: Sendable {
    func snapshot() async -> ThermalSnapshot
    func resetAfterWake() async
}

/// Read-only access to the Apple SMC user client. Fan writes intentionally do not exist in this type.
/// The wire layout follows the public MIT-licensed research cited in THIRD_PARTY_NOTICES.md.
final class SMCConnection: @unchecked Sendable {
    enum Error: Swift.Error, LocalizedError {
        case connectionFailed
        case ioKit(kern_return_t)
        case invalidKey
        case invalidPayloadSize(UInt32)
        case unsupportedWireLayout(Int)
        case firmware(UInt8)

        var errorDescription: String? {
            switch self {
            case .connectionFailed: "Could not open the Apple SMC read-only client."
            case .ioKit(let code): "Apple SMC IOKit error 0x\(String(code, radix: 16))."
            case .invalidKey: "The SMC key must contain exactly four ASCII characters."
            case .invalidPayloadSize(let size): "Apple SMC returned an unsupported payload size (\(size) bytes)."
            case .unsupportedWireLayout(let size): "The Apple SMC parameter block has an unsupported layout (\(size) bytes)."
            case .firmware(let result): "Apple SMC rejected the read (0x\(String(result, radix: 16)))."
            }
        }
    }

    private enum Command: UInt8 {
        case kernelIndex = 2
        case readBytes = 5
        case readIndex = 8
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

    /// The AppleSMC client accepts an 80-byte parameter block.
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

    struct KeyInfo: Sendable {
        let size: UInt32
        let type: String
    }

    private let connection: io_connect_t
    private var keyInfoCache: [String: KeyInfo] = [:]

    init() throws {
        let wireSize = MemoryLayout<Param>.stride
        guard wireSize == 80 else { throw Error.unsupportedWireLayout(wireSize) }
        var iterator: io_iterator_t = 0
        let matchingNames = ["AppleSMC", "AppleSMCKeysEndpoint"]
        var foundService: io_service_t = 0

        for matchingName in matchingNames {
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(matchingName), &iterator) == kIOReturnSuccess else {
                continue
            }
            let candidate = IOIteratorNext(iterator)
            IOObjectRelease(iterator)
            iterator = 0
            if candidate != 0 {
                foundService = candidate
                break
            }
        }

        guard foundService != 0 else { throw Error.connectionFailed }
        defer { IOObjectRelease(foundService) }

        var opened: io_connect_t = 0
        let result = IOServiceOpen(foundService, mach_task_self_, 0, &opened)
        guard result == kIOReturnSuccess else { throw Error.ioKit(result) }
        connection = opened
    }

    deinit { IOServiceClose(connection) }

    func keyInfo(for key: String) throws -> KeyInfo {
        if let cached = keyInfoCache[key] { return cached }
        var input = Param()
        input.key = try fourCharacterCode(key)
        input.data8 = Command.readKeyInfo.rawValue
        let output = try call(input)
        guard output.result == 0 else { throw Error.firmware(output.result) }
        var type = output.keyInfo.dataType.bigEndian
        let bytes = withUnsafeBytes(of: &type) { Array($0) }
        let info = KeyInfo(size: output.keyInfo.dataSize, type: String(bytes: bytes, encoding: .ascii) ?? "????")
        keyInfoCache[key] = info
        return info
    }

    func read(key: String) throws -> (bytes: [UInt8], info: KeyInfo) {
        let info = try keyInfo(for: key)
        guard info.size <= 32 else { throw Error.invalidPayloadSize(info.size) }
        var input = Param()
        input.key = try fourCharacterCode(key)
        input.keyInfo.dataSize = info.size
        input.data8 = Command.readBytes.rawValue
        let output = try call(input)
        guard output.result == 0 else { throw Error.firmware(output.result) }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }
        return (bytes, info)
    }

    func enumerateKeys(limit: Int = 1_600) -> [String] {
        guard let count = try? readUInt32(key: "#KEY") else { return [] }
        let boundedCount = min(Int(count), limit)
        var result: [String] = []
        result.reserveCapacity(boundedCount)

        for index in 0..<boundedCount {
            var input = Param()
            input.data8 = Command.readIndex.rawValue
            input.data32 = UInt32(index)
            guard let output = try? call(input), output.result == 0 else { continue }
            let key = string(from: output.key)
            if key.count == 4 { result.append(key) }
        }
        return result
    }

    func readFloat(key: String) throws -> Double {
        let value = try read(key: key)
        if value.info.size == 4, value.bytes.count >= 4 {
            let bits = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Double(Float(bitPattern: bits))
        }
        guard value.bytes.count >= 2 else { throw Error.invalidPayloadSize(value.info.size) }
        let raw = value.bytes.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) }
        return Double(raw) / 4.0
    }

    func readTemperature(key: String) throws -> Double? {
        let value = try read(key: key)
        switch value.info.type {
        case "sp78":
            guard value.bytes.count >= 2 else { return nil }
            let raw = value.bytes.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) }
            return Double(Int16(bitPattern: raw)) / 256.0
        case "flt ", "flt":
            guard value.bytes.count >= 4 else { return nil }
            let bits = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Double(Float(bitPattern: bits))
        default:
            return nil
        }
    }

    func readUInt8(key: String) throws -> UInt8 {
        let value = try read(key: key)
        guard let first = value.bytes.first else { throw Error.firmware(0x83) }
        return first
    }

    private func readUInt32(key: String) throws -> UInt32 {
        let value = try read(key: key)
        guard value.bytes.count >= 4 else { throw Error.firmware(0x83) }
        return value.bytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
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
        guard result == kIOReturnSuccess else { throw Error.ioKit(result) }
        guard outputSize == MemoryLayout<Param>.stride else { throw Error.invalidPayloadSize(UInt32(outputSize)) }
        return output
    }

    private func fourCharacterCode(_ string: String) throws -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { throw Error.invalidKey }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func string(from code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

private struct SMCDiscovery: Sendable {
    struct FanDescriptor: Sendable {
        let index: Int
        let minimumRPM: Double
        let maximumRPM: Double
    }

    struct SensorDescriptor: Sendable {
        let key: String
        let name: String
    }

    let fans: [FanDescriptor]
    let sensors: [SensorDescriptor]

    static func make(using connection: SMCConnection) -> SMCDiscovery {
        let fanCount = min(Int((try? connection.readUInt8(key: "FNum")) ?? 0), 8)
        let fanIndices: [Int]
        if fanCount > 0 {
            fanIndices = Array(0..<fanCount)
        } else {
            fanIndices = (0..<8).filter { (try? connection.keyInfo(for: "F\($0)Ac")) != nil }
        }

        let preferred = [
            // Apple-silicon die hot spots first, followed by older/fallback
            // CPU and GPU zones. Missing keys are simply ignored at discovery.
            "TCMz", "TCMb", "TRDX",
            "Tp0P", "Tp0T", "Tp1T", "Tp2T", "Tp3T", "Tp4T",
            "Te04", "Te05", "Te06",
            "Tg0e", "Tg0f", "Tg0g", "Tg0h", "Tg0i", "Tg0j", "Tg0r",
            "TC0P", "TC0E", "TC0F", "TC0D", "TG0P", "TG0D", "TG0T", "TB0T"
        ]
        // Probe the small known set directly. Enumerating ~1,600 SMC keys made
        // first launch feel frozen on Apple silicon even though only a few
        // temperature keys are needed.
        var selected = preferred.filter { key in
            guard let info = try? connection.keyInfo(for: key) else { return false }
            return info.type == "sp78" || info.type == "flt " || info.type == "flt"
        }

        if selected.count < 2 {
            let keys = Set(connection.enumerateKeys())
            let dynamic = keys
                .filter { $0.first == "T" }
                .sorted()
                .prefix(48)
                .filter { key in
                    guard let info = try? connection.keyInfo(for: key) else { return false }
                    return info.type == "sp78" || info.type == "flt " || info.type == "flt"
                }
            selected = Array(Set(selected).union(dynamic)).sorted()
        }

        let fans = fanIndices.map { index in
            let minimum = (try? connection.readFloat(key: "F\(index)Mn"))
                .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            let maximum = (try? connection.readFloat(key: "F\(index)Mx"))
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? max(minimum + 1, 1)
            return FanDescriptor(index: index, minimumRPM: minimum, maximumRPM: max(maximum, minimum + 1))
        }
        return SMCDiscovery(
            fans: fans,
            sensors: selected.map { SensorDescriptor(key: $0, name: sensorName(for: $0)) }
        )
    }

    private static func sensorName(for key: String) -> String {
        if key == "TRDX" || key.hasPrefix("TG") || key.hasPrefix("Tg") { return "GPU thermal" }
        if key.hasPrefix("TP") || key.hasPrefix("Tp") || key.hasPrefix("TC") || key.hasPrefix("Te") { return "CPU thermal" }
        if key.hasPrefix("TB") { return "Battery" }
        return "Thermal \(key)"
    }
}

actor AppleSMCTelemetryService: ThermalTelemetryProviding {
    private var connection: SMCConnection?
    private var discovery: SMCDiscovery?
    private var unavailableReason: String?

    // Cache the expensive discovery results across snapshots (only invalidated on wake/error).
    // This avoids re-probing fan min/max and sensor key lists on every 2-15s tick.
    private var cachedFanDescriptors: [SMCDiscovery.FanDescriptor]?
    private var cachedSensorDescriptors: [SMCDiscovery.SensorDescriptor]?

    init() {
        do {
            connection = try SMCConnection()
            unavailableReason = nil
        } catch {
            connection = nil
            unavailableReason = error.localizedDescription
        }
    }

    func snapshot() -> ThermalSnapshot {
        if connection == nil { reconnect() }
        guard let connection else {
            return ThermalSnapshot(
                timestamp: .now,
                hottest: nil,
                cpu: nil,
                gpu: nil,
                fans: [],
                sensors: [],
                sourceStatus: unavailableReason ?? "Apple SMC telemetry is unavailable."
            )
        }

        // Use cached discovery (populated once) to avoid repeated fan/sensor probing.
        if discovery == nil {
            discovery = SMCDiscovery.make(using: connection)
            cachedFanDescriptors = discovery?.fans
            cachedSensorDescriptors = discovery?.sensors
        }
        guard discovery != nil,
              let fanDescs = cachedFanDescriptors,
              let sensorDescs = cachedSensorDescriptors else { return .unavailable }

        // The fastest sampling tick is 2 s, so a sub-second value cache never
        // hits; every read goes straight to the SMC connection.
        let sensors = sensorDescs.compactMap { descriptor -> SensorReading? in
            guard let temperature = try? connection.readTemperature(key: descriptor.key),
                  (-10...130).contains(temperature) else { return nil }
            return SensorReading(key: descriptor.key, name: descriptor.name, celsius: temperature)
        }

        let fans = fanDescs.compactMap { descriptor -> FanReading? in
            guard let actual = try? connection.readFloat(key: "F\(descriptor.index)Ac"), actual.isFinite, actual >= 0 else { return nil }
            let target = (try? connection.readFloat(key: "F\(descriptor.index)Tg"))
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return FanReading(
                id: descriptor.index,
                name: fanDescs.count == 2 ? (descriptor.index == 0 ? "Left fan" : "Right fan") : "Fan \(descriptor.index + 1)",
                actualRPM: actual,
                minimumRPM: descriptor.minimumRPM,
                maximumRPM: descriptor.maximumRPM,
                firmwareTargetRPM: target
            )
        }

        let cpu = sensors.filter { $0.name.contains("CPU") }.max { $0.celsius < $1.celsius }
        let gpu = sensors.filter { $0.name.contains("GPU") }.max { $0.celsius < $1.celsius }
        let hottest = [cpu, gpu].compactMap { $0 }.max { $0.celsius < $1.celsius }
            ?? sensors.max { $0.celsius < $1.celsius }
        let status = sensors.isEmpty
            ? "Apple SMC opened, but no readable thermal sensors were found."
            : "Live Apple SMC · \(sensors.count) sensors · \(fans.count) fan\(fans.count == 1 ? "" : "s")"

        return ThermalSnapshot(
            timestamp: .now,
            hottest: hottest,
            cpu: cpu,
            gpu: gpu,
            fans: fans,
            // Canonical ordering prevents two similarly warm sensors swapping
            // position from looking like a brand-new snapshot to the UI.
            // Screens that need a heat ranking sort their local presentation.
            sensors: sensors.sorted { $0.key < $1.key },
            sourceStatus: status
        )
    }

    func resetAfterWake() {
        connection = nil
        discovery = nil
        cachedFanDescriptors = nil
        cachedSensorDescriptors = nil
        reconnect()
    }

    private func reconnect() {
        do {
            connection = try SMCConnection()
            unavailableReason = nil
        } catch {
            connection = nil
            unavailableReason = error.localizedDescription
        }
    }
}

/// Deterministic, in-memory fixture used only by UI tests. It never opens Apple SMC
/// and keeps test runs from touching the user's telemetry database.
actor FixtureTelemetryService: ThermalTelemetryProviding {
    private var tick = 0

    func snapshot() -> ThermalSnapshot {
        tick += 1
        let phase = Double(tick % 24) / 24
        let temperature = 56 + sin(phase * .pi * 2) * 5
        let left = 3_100 + sin(phase * .pi * 2) * 380
        let right = 3_160 + cos(phase * .pi * 2) * 360
        let sensors = [
            SensorReading(key: "TC0P", name: "CPU thermal", celsius: temperature),
            SensorReading(key: "TG0P", name: "GPU thermal", celsius: temperature - 2.5),
            SensorReading(key: "TB0T", name: "Battery", celsius: 34)
        ]
        return ThermalSnapshot(
            timestamp: .now,
            hottest: sensors[0],
            cpu: sensors[0],
            gpu: sensors[1],
            fans: [
                FanReading(id: 0, name: "Left fan", actualRPM: left, minimumRPM: 2_317, maximumRPM: 6_800, firmwareTargetRPM: nil),
                FanReading(id: 1, name: "Right fan", actualRPM: right, minimumRPM: 2_317, maximumRPM: 6_800, firmwareTargetRPM: nil)
            ],
            sensors: sensors,
            sourceStatus: "UI test fixture · local and isolated"
        )
    }

    func resetAfterWake() { }
}
