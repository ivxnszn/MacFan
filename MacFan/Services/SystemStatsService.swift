import Darwin
import Foundation
import IOKit
import IOKit.ps

struct SystemUsage: Sendable, Equatable {
    var cpuTotalPercent: Double
    var perCorePercent: [Double]
    var memoryUsedBytes: UInt64
    var memoryTotalBytes: UInt64
    var swapUsedBytes: UInt64
    var gpuPercent: Double?
    var loadAverage: Double
    var uptime: TimeInterval
    /// ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    var thermalStateRaw: Int = 0
    var batteryPercent: Double?
    var batteryCharging: Bool?
    var batteryMinutesRemaining: Int?
    /// Power in watts (positive value). Computed as |current(mA)| × voltage(mV) / 1_000_000
    /// from IOPS ("Current") + AppleSmartBattery/SMC ("Voltage", "AppleRawBatteryVoltage", "Amperage").
    /// Especially accurate and prominent for charging power (W).
    var batteryWatts: Double?
    /// Battery health as percentage of design capacity (if available).
    var batteryHealthPercent: Double?
    var batteryCycleCount: Int?
    /// Adapter reported watts when available (via IOPS external adapter details).
    var batteryAdapterWatts: Double?
    /// Battery temperature in °C from power source registry (if available).
    var batteryTempC: Double?
    /// Instant current in mA (signed; sign convention varies). Use abs(currentMA) for power.
    var batteryCurrentMA: Double?
    /// Voltage in mV from IOPS or SMC/AppleSmartBattery registry.
    var batteryVoltageMV: Double?
    var diskUsedBytes: UInt64 = 0
    var diskTotalBytes: UInt64 = 0
    /// nil until two samples exist (rates are deltas).
    var networkReceivedKBps: Double?
    var networkSentKBps: Double?

    var memoryPercent: Double {
        memoryTotalBytes == 0 ? 0 : Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100
    }

    var diskPercent: Double {
        diskTotalBytes == 0 ? 0 : Double(diskUsedBytes) / Double(diskTotalBytes) * 100
    }

    var thermalStateTitle: String {
        switch thermalStateRaw {
        case 1: "Fair"
        case 2: "Serious"
        case 3: "Critical"
        default: "Nominal"
        }
    }
}

/// Basic hardware specs for "hacking the data" - scannable, tappable for more.
struct MacSpecs: Equatable {
    let model: String          // raw identifier e.g. "Mac15,6" (for tech details only; hidden from primary UI)
    let name: String           // friendly marketing name e.g. "MacBook Pro 14\" M3 Pro 2023"
    let cpuBrand: String       // e.g. "Apple M3 Pro" (kept for reference)
    let physicalCores: Int
    let logicalCores: Int
    let cpuPCores: Int         // Performance cores (Apple silicon); falls back to physical on Intel
    let cpuECores: Int         // Efficiency cores (0 on Intel)
    let memoryGB: Int
    let gpu: String?           // e.g. "14-core GPU" or "Apple GPU"; never raw SoC name
    let gpuCores: Int?         // numeric count when available (e.g. 14)
    let maxCPUMHz: Int?
    let l2CacheMB: Int?
    let l3CacheMB: Int?
    let smcVersion: String?
    let firmwareVersion: String?
}

/// Lightweight static map for common Apple silicon (and select Intel) model identifiers.
/// Produces beautiful, useful names instead of opaque "Mac15,6".
private let macModelMap: [String: (base: String, year: String)] = [
    // MacBook Pro 14/16" Nov 2023 (M3 family)
    "Mac15,3": ("MacBook Pro 14\"", "2023"),
    "Mac15,6": ("MacBook Pro 14\"", "2023"),
    "Mac15,7": ("MacBook Pro 16\"", "2023"),
    "Mac15,8": ("MacBook Pro 14\"", "2023"),
    "Mac15,9": ("MacBook Pro 16\"", "2023"),
    "Mac15,10": ("MacBook Pro 14\"", "2023"),
    "Mac15,11": ("MacBook Pro 16\"", "2023"),
    // MacBook Air M3 2024 / M2 2023
    "Mac15,12": ("MacBook Air 13\"", "2024"),
    "Mac14,2": ("MacBook Air 13\"", "2023"),
    "Mac14,15": ("MacBook Air 15\"", "2023"),
    // Desktops
    "Mac14,3": ("Mac mini", "2023"),
    "Mac14,12": ("Mac mini", "2024"),
    "Mac14,13": ("Mac Studio", "2023"),
    "Mac14,14": ("Mac Studio", "2023"),
    "Mac13,1": ("Mac Studio", "2022"),
    "Mac13,2": ("Mac Studio", "2022"),
    // MacBook Pro M2 2023 / M1 2021 (selected)
    "Mac14,5": ("MacBook Pro 14\"", "2023"),
    "Mac14,6": ("MacBook Pro 16\"", "2023"),
    "Mac14,9": ("MacBook Pro 14\"", "2023"),
    "Mac14,10": ("MacBook Pro 16\"", "2023"),
    "MacBookPro18,1": ("MacBook Pro 16\"", "2021"),
    "MacBookPro18,2": ("MacBook Pro 16\"", "2021"),
    "MacBookPro18,3": ("MacBook Pro 14\"", "2021"),
    "MacBookPro18,4": ("MacBook Pro 14\"", "2021"),
    "Macmini9,1": ("Mac mini", "2020"),
]

private func friendlyModelName(model: String, cpuBrand: String) -> String {
    let chip = cpuBrand.replacingOccurrences(of: "Apple ", with: "")
    if let (base, year) = macModelMap[model] {
        if base.hasPrefix("MacBook") || base.contains("Air") {
            return "\(base) \(chip) \(year)"
        }
        return "\(base) \(chip) \(year)"
    }
    // Fallback keeps it useful even for unlisted or Intel models
    if chip.isEmpty || chip == model {
        return model
    }
    return "\(model) (\(chip))"
}

func fetchMacSpecs() -> MacSpecs {
    struct Cache {
        static var specs: MacSpecs?
    }
    if let cached = Cache.specs { return cached }

    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    let modelStr = String(cString: model)

    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var brand = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
    let cpuStr = String(cString: brand)

    let name = friendlyModelName(model: modelStr, cpuBrand: cpuStr)

    var cores: Int32 = 0
    var logical: Int32 = 0
    var mem: UInt64 = 0
    var freq: Int64 = 0
    var l2: Int64 = 0
    var l3: Int64 = 0
    var len = MemoryLayout<Int32>.size
    sysctlbyname("hw.physicalcpu", &cores, &len, nil, 0)
    sysctlbyname("hw.logicalcpu", &logical, &len, nil, 0)
    len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &mem, &len, nil, 0)
    len = MemoryLayout<Int64>.size
    sysctlbyname("hw.cpufrequency_max", &freq, &len, nil, 0)
    sysctlbyname("hw.l2cachesize", &l2, &len, nil, 0)
    sysctlbyname("hw.l3cachesize", &l3, &len, nil, 0)

    // Apple silicon perf levels for accurate P/E breakdown + better cache (lightweight sysctl)
    var pCores: Int32 = 0
    var eCores: Int32 = 0
    var pL2: Int64 = 0
    var eL2: Int64 = 0
    var len32 = MemoryLayout<Int32>.size
    var len64 = MemoryLayout<Int64>.size
    _ = sysctlbyname("hw.perflevel0.physicalcpu", &pCores, &len32, nil, 0)
    _ = sysctlbyname("hw.perflevel1.physicalcpu", &eCores, &len32, nil, 0)
    _ = sysctlbyname("hw.perflevel0.l2cachesize", &pL2, &len64, nil, 0)
    _ = sysctlbyname("hw.perflevel1.l2cachesize", &eL2, &len64, nil, 0)

    let memGB = Int(mem / 1_073_741_824)
    let maxMHz = freq > 0 ? Int(freq / 1_000_000) : nil
    let l3MB = l3 > 0 ? Int(l3 / 1_048_576) : nil
    let l2MB: Int? = (pL2 + eL2) > 0 ? Int((pL2 + eL2) / 1_048_576) : (l2 > 0 ? Int(l2 / 1_048_576) : nil)

    let phys = Int(cores)
    let pc = pCores > 0 ? Int(pCores) : phys
    let ec = eCores > 0 ? Int(eCores) : 0

    // GPU via IOKit (simple name). On Apple Silicon this is often the SoC name
    // (same as cpuBrand); callers should not label it "GPU".
    // Also read gpu-core-count for useful detail (e.g. 14 on M3 Pro).
    var gpuStr: String? = nil
    var gpuCoreCount: Int? = nil
    if let service = IOServiceMatching("IOAccelerator") {
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, service, &iterator) == KERN_SUCCESS {
            let obj = IOIteratorNext(iterator)
            if obj != 0 {
                if let name = IORegistryEntryCreateCFProperty(obj, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    gpuStr = name
                }
                if let n = IORegistryEntryCreateCFProperty(obj, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                    gpuCoreCount = n.intValue
                }
                IOObjectRelease(obj)
            }
            IOObjectRelease(iterator)
        }
    }

    // Fix GPU label: never expose SoC/CPU name (e.g. "Apple M3 Pro") as GPU.
    // For Apple Silicon use "N-core GPU" (beautiful + useful). Fallback generic.
    if let g = gpuStr, g.trimmingCharacters(in: .whitespacesAndNewlines) == cpuStr.trimmingCharacters(in: .whitespacesAndNewlines) || g.hasPrefix("Apple ") {
        if let gc = gpuCoreCount, gc > 0 {
            gpuStr = "\(gc)-core GPU"
        } else {
            gpuStr = "Apple GPU"
        }
    } else if gpuStr == nil, let gc = gpuCoreCount, gc > 0 {
        gpuStr = "\(gc)-core GPU"
    }

    // SMC revision and firmware (simple)
    let smcVer: String? = nil // extend with SMC read if needed
    let fwVer: String? = nil

    let result = MacSpecs(
        model: modelStr,
        name: name,
        cpuBrand: cpuStr,
        physicalCores: phys,
        logicalCores: Int(logical),
        cpuPCores: pc,
        cpuECores: ec,
        memoryGB: memGB,
        gpu: gpuStr,
        gpuCores: gpuCoreCount,
        maxCPUMHz: maxMHz,
        l2CacheMB: l2MB,
        l3CacheMB: l3MB,
        smcVersion: smcVer,
        firmwareVersion: fwVer
    )
    Cache.specs = result
    return result
}

/// Host-level usage counters for the System tab. A stable instance preserves
/// the short session trail, but its single sampling task only runs while that
/// tab is visible.
///
/// Battery/power sampling: 5s interval for responsive Watts (especially charging power
/// computed from IOPS current × SMC/AppleSmartBattery voltage). Still very lightweight
/// (IOReg + IOPS are cheap); full health/cycles change slowly but we refresh together.
/// 144 Hz friendly: numeric transitions + bucketed publishes keep UI smooth/light.

actor SystemUsageSampler {
    private var previousTicks: [[UInt32]] = []
    private var previousNetworkTotals: (received: UInt64, sent: UInt64, at: Date)?
    private var cachedGPU: Double?
    private var lastGPURead = Date.distantPast
    private var cachedBattery: (percent: Double, charging: Bool, minutesRemaining: Int?, watts: Double?, healthPercent: Double?, cycleCount: Int?, adapterWatts: Double?, tempC: Double?, currentMA: Double?, voltageMV: Double?)?
    private var lastBatteryRead = Date.distantPast
    private var cachedDisk: (used: UInt64, total: UInt64) = (0, 0)
    private var lastDiskRead = Date.distantPast

    /// Delta counters cannot report honest CPU/network activity from a single
    /// read. Prime them over a short interval so the first visible card never
    /// flashes a misleading "0% / 0 cores" state.
    func primedSample() async -> SystemUsage {
        _ = sample()
        try? await Task.sleep(for: .milliseconds(160))
        return sample()
    }

    func sample() -> SystemUsage {
        var perCore: [Double] = []
        var totalBusy = 0.0
        var totalAll = 0.0

        if let current = readCPUTicks() {
            if previousTicks.count == current.count {
                for (previous, now) in zip(previousTicks, current) {
                    let user = Double(now[Int(CPU_STATE_USER)] &- previous[Int(CPU_STATE_USER)])
                    let system = Double(now[Int(CPU_STATE_SYSTEM)] &- previous[Int(CPU_STATE_SYSTEM)])
                    let nice = Double(now[Int(CPU_STATE_NICE)] &- previous[Int(CPU_STATE_NICE)])
                    let idle = Double(now[Int(CPU_STATE_IDLE)] &- previous[Int(CPU_STATE_IDLE)])
                    let busy = user + system + nice
                    let all = busy + idle
                    perCore.append(all > 0 ? busy / all * 100 : 0)
                    totalBusy += busy
                    totalAll += all
                }
            }
            previousTicks = current
        }

        let now = Date.now
        let memory = readMemory()
        if now.timeIntervalSince(lastGPURead) >= 4 {
            cachedGPU = readGPUUtilization()
            lastGPURead = now
        }
        if now.timeIntervalSince(lastBatteryRead) >= 5 {
            cachedBattery = readBattery()
            lastBatteryRead = now
        }
        if now.timeIntervalSince(lastDiskRead) >= 60 {
            cachedDisk = readDisk()
            lastDiskRead = now
        }
        let network = readNetworkRates()
        return SystemUsage(
            cpuTotalPercent: totalAll > 0 ? totalBusy / totalAll * 100 : 0,
            perCorePercent: perCore,
            memoryUsedBytes: memory.used,
            memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            swapUsedBytes: readSwapUsed(),
            gpuPercent: cachedGPU,
            loadAverage: readLoadAverage(),
            uptime: ProcessInfo.processInfo.systemUptime,
            thermalStateRaw: ProcessInfo.processInfo.thermalState.rawValue,
            batteryPercent: cachedBattery?.percent,
            batteryCharging: cachedBattery?.charging,
            batteryMinutesRemaining: cachedBattery?.minutesRemaining,
            batteryWatts: cachedBattery?.watts,
            batteryHealthPercent: cachedBattery?.healthPercent,
            batteryCycleCount: cachedBattery?.cycleCount,
            batteryAdapterWatts: cachedBattery?.adapterWatts,
            batteryTempC: cachedBattery?.tempC,
            batteryCurrentMA: cachedBattery?.currentMA,
            batteryVoltageMV: cachedBattery?.voltageMV,
            diskUsedBytes: cachedDisk.used,
            diskTotalBytes: cachedDisk.total,
            networkReceivedKBps: network?.receivedKBps,
            networkSentKBps: network?.sentKBps
        )
    }

    /// Internal battery via IOPowerSources + AppleSmartBattery IORegistry (SMC-backed) for rich data.
    /// Returns nil on desktop Macs without internal battery. Lightweight: 5s for power (W) updates.
    /// Power (W) = |current(mA)| × voltage(mV) / 1_000_000. Prioritizes IOPS "Current" + registry/SMC
    /// "Voltage"/"AppleRawBatteryVoltage" (or IOPS "Voltage"). Falls back to Amperage (SMC). Always abs
    /// so watts positive; emphasized for charging scenarios.
    private func readBattery() -> (percent: Double, charging: Bool, minutesRemaining: Int?, watts: Double?, healthPercent: Double?, cycleCount: Int?, adapterWatts: Double?, tempC: Double?, currentMA: Double?, voltageMV: Double?)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        var percent: Double?
        var charging = false
        var minutes: Int?
        var currentMA: Double?
        var voltageFromIOPS: Double?
        var iopsHealth: String?
        var designCycles: Int?

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            if let cur = description[kIOPSCurrentCapacityKey] as? Int,
               let maxc = description[kIOPSMaxCapacityKey] as? Int, maxc > 0 {
                percent = Double(cur) / Double(maxc) * 100
            }
            charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            if let curNum = description["Current"] as? NSNumber {
                currentMA = curNum.doubleValue
            }
            if let vNum = description["Voltage"] as? NSNumber {
                voltageFromIOPS = vNum.doubleValue
            } else if let v = description["Voltage"] as? Int {
                voltageFromIOPS = Double(v)
            }
            let rawMinutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            minutes = (rawMinutes ?? -1) > 0 ? rawMinutes : nil
            iopsHealth = description["BatteryHealth"] as? String
            designCycles = description["DesignCycleCount"] as? Int
            break
        }

        guard percent != nil else { return nil }

        // Rich data via AppleSmartBattery registry entry (SMC data). Keys: Voltage, AppleRaw*, Amperage, etc.
        var cycleCount: Int?
        var voltageMV: Double?
        var tempC: Double?
        var nomCap: Int?
        var desCap: Int?
        var smcAmperage: Double?

        var battIterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &battIterator) == KERN_SUCCESS {
            defer { IOObjectRelease(battIterator) }
            let entry = IOIteratorNext(battIterator)
            if entry != 0 {
                defer { IOObjectRelease(entry) }
                if let c = IORegistryEntryCreateCFProperty(entry, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    cycleCount = c
                }
                if let v = IORegistryEntryCreateCFProperty(entry, "Voltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    voltageMV = Double(v)
                } else if let v = IORegistryEntryCreateCFProperty(entry, "AppleRawBatteryVoltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    voltageMV = Double(v)
                }
                if let t = IORegistryEntryCreateCFProperty(entry, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    // 10th of a Kelvin (typical): 3077 -> ~34.55 °C
                    tempC = Double(t) / 10.0 - 273.15
                }
                if let n = IORegistryEntryCreateCFProperty(entry, "NominalChargeCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    nomCap = n
                }
                if let d = IORegistryEntryCreateCFProperty(entry, "DesignCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    desCap = d
                }
                // SMC Amperage (signed mA, large uint64 often represents negative when discharging)
                if let a = IORegistryEntryCreateCFProperty(entry, "Amperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int64 {
                    smcAmperage = Double(a)
                } else if let a = IORegistryEntryCreateCFProperty(entry, "Amperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    smcAmperage = Double(a)
                } else if let a = IORegistryEntryCreateCFProperty(entry, "InstantAmperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int64 {
                    smcAmperage = Double(a)
                }
            }
        }

        // Prefer IOPS current; fallback to SMC Amperage if IOPS missing (rare).
        if currentMA == nil, let sma = smcAmperage {
            currentMA = sma
        }
        // Prefer registry/SMC voltage; fallback to IOPS voltage if present.
        if voltageMV == nil, let vi = voltageFromIOPS {
            voltageMV = vi
        }

        // Compute watts from IOPS or SMC sources: |mA| * mV / 1e6 . Positive always.
        var watts: Double?
        if let ma = currentMA, let mv = voltageMV, mv > 0 {
            watts = abs(ma) * mv / 1_000_000.0
        }

        // Health: prefer Nominal/Design from registry (full charge capacity vs design). Fallback to IOPS max or 100.
        var healthPercent: Double?
        if let nom = nomCap, let des = desCap, des > 0 {
            healthPercent = min(100.0, max(0.0, Double(nom) / Double(des) * 100.0))
        } else if let hstr = iopsHealth, hstr.lowercased().contains("good") {
            healthPercent = 100.0
        } else if percent != nil {
            // IOPS Max Capacity often reflects health % already on some firmwares
            healthPercent = percent
        }

        // Adapter details (only present when AC/external connected). Provides direct Watts.
        var adapterWatts: Double?
        if let ad = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            if let w = (ad["Watts"] as? NSNumber)?.doubleValue ?? (ad["Watts"] as? Int).map(Double.init) {
                adapterWatts = w
            }
        }

        let usedCycles = cycleCount ?? designCycles
        return (percent!, charging, minutes, watts, healthPercent, usedCycles, adapterWatts, tempC, currentMA, voltageMV)
    }

    /// Byte counters summed over non-loopback link-layer interfaces; rates are
    /// deltas against the previous sample. Counter resets simply yield nil.
    private func readNetworkRates() -> (receivedKBps: Double, sentKBps: Double)? {
        guard let totals = readNetworkTotals() else { return nil }
        let now = Date.now
        defer { previousNetworkTotals = (totals.received, totals.sent, now) }
        guard let previous = previousNetworkTotals,
              totals.received >= previous.received,
              totals.sent >= previous.sent else { return nil }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0.2 else { return nil }
        return (
            Double(totals.received - previous.received) / elapsed / 1_024,
            Double(totals.sent - previous.sent) / elapsed / 1_024
        )
    }

    private func readNetworkTotals() -> (received: UInt64, sent: UInt64)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor = addresses
        while let entry = cursor {
            let interface = entry.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               let dataPointer = interface.ifa_data,
               let name = String(validatingUTF8: interface.ifa_name), !name.hasPrefix("lo") {
                let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                received &+= UInt64(data.ifi_ibytes)
                sent &+= UInt64(data.ifi_obytes)
            }
            cursor = interface.ifa_next
        }
        return (received, sent)
    }

    private func readDisk() -> (used: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage,
              total > 0 else { return (0, 0) }
        let totalBytes = UInt64(total)
        let availableBytes = UInt64(max(available, 0))
        return (totalBytes > availableBytes ? totalBytes - availableBytes : 0, totalBytes)
    }

    private func readCPUTicks() -> [[UInt32]]? {
        var processorCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &infoArray,
            &infoCount
        ) == KERN_SUCCESS, let infoArray else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: infoArray)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let states = Int(CPU_STATE_MAX)
        return (0..<Int(processorCount)).map { cpu in
            (0..<states).map { state in UInt32(bitPattern: infoArray[cpu * states + state]) }
        }
    }

    private func readMemory() -> (used: UInt64, free: UInt64) {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let pageSize = UInt64(vm_kernel_page_size)
        // Matches Activity Monitor's "memory used": app + wired + compressed.
        let used = (UInt64(statistics.active_count) + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)) * pageSize
        let free = UInt64(statistics.free_count) * pageSize
        return (used, free)
    }

    private func readSwapUsed() -> UInt64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return swap.xsu_used
    }

    private func readLoadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) >= 1 ? loads[0] : 0
    }

    /// Apple GPUs report utilization through the IOAccelerator registry entry.
    /// Absent or unreadable statistics simply yield nil ("—" in the UI).
    private func readGPUUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { return nil }
            defer { IOObjectRelease(entry) }

            var propertiesRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = propertiesRef?.takeRetainedValue() as? [String: Any],
                  let statistics = properties["PerformanceStatistics"] as? [String: Any] else { continue }
            let value = (statistics["Device Utilization %"] as? NSNumber)
                ?? (statistics["GPU Activity(%)"] as? NSNumber)
            if let value { return min(max(value.doubleValue, 0), 100) }
        }
    }
}
