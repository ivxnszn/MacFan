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

/// Host-level usage counters for the System tab. A stable instance preserves
/// the short session trail, but its single sampling task only runs while that
/// tab is visible.
actor SystemUsageSampler {
    private var previousTicks: [[UInt32]] = []
    private var previousNetworkTotals: (received: UInt64, sent: UInt64, at: Date)?
    private var cachedGPU: Double?
    private var lastGPURead = Date.distantPast
    private var cachedBattery: (percent: Double, charging: Bool, minutesRemaining: Int?)?
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
        if now.timeIntervalSince(lastBatteryRead) >= 20 {
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
            diskUsedBytes: cachedDisk.used,
            diskTotalBytes: cachedDisk.total,
            networkReceivedKBps: network?.receivedKBps,
            networkSentKBps: network?.sentKBps
        )
    }

    /// Internal battery via IOPowerSources; nil on Macs without one.
    private func readBattery() -> (percent: Double, charging: Bool, minutesRemaining: Int?)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let rawMinutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            let minutes = (rawMinutes ?? -1) > 0 ? rawMinutes : nil
            return (Double(current) / Double(maximum) * 100, charging, minutes)
        }
        return nil
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
