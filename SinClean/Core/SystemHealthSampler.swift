import CoreGraphics
import Darwin
import Foundation
import IOKit.ps

// SC-4 采样器：只读取系统指标接口与电源/会话状态。
// 边界（work/SC-4-frozen-semantics.md B1）：不枚举用户目录、不触碰任何文件、不发起任何网络请求。

struct SystemHealthSample: Equatable, Sendable {
    let capturedAt: Date
    /// §1：档位只由系统内存压力事实决定。
    let memoryPressure: MemoryPressureLevel
    let memoryPressureRawValue: Int32?
    /// 以下两项只作证据展示，不参与档位判定。
    let memoryUsedBytes: UInt64
    let physicalMemoryBytes: UInt64
    let compressorBytes: UInt64
    let cpuLoad: Double
    let processorCount: Int
    let volumeFreeBytes: Int64
    let volumeTotalBytes: Int64
    let battery: BatterySnapshot?
    let externalDriveCount: Int
    let lowPowerModeEnabled: Bool
    let screenLocked: Bool
    let network: NetworkSnapshot
    let uptime: TimeInterval

    var volumeFreeRatio: Double? {
        guard volumeTotalBytes > 0 else { return nil }
        return Double(volumeFreeBytes) / Double(volumeTotalBytes)
    }

    var memoryUsedRatio: Double {
        guard physicalMemoryBytes > 0 else { return 0 }
        return min(1, Double(memoryUsedBytes) / Double(physicalMemoryBytes))
    }
}

protocol SystemHealthSampling: Sendable {
    func sample() async -> SystemHealthSample
}

actor SystemHealthSampler: SystemHealthSampling {
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var previousNetworkCounters: (inbound: UInt64, outbound: UInt64)?
    private var previousNetworkDate: Date?

    func sample() async -> SystemHealthSample {
        let date = Date()
        let pressureRaw = Self.memoryPressureRawValue()
        let memory = Self.memoryFacts()
        let volume = Self.volumeFacts()
        let cpuLoad = currentCPULoad()
        let network = networkSnapshot(at: date)

        return SystemHealthSample(
            capturedAt: date,
            memoryPressure: MemoryPressureLevel.from(kernelValue: pressureRaw),
            memoryPressureRawValue: pressureRaw,
            memoryUsedBytes: memory.used,
            physicalMemoryBytes: memory.total,
            compressorBytes: memory.compressor,
            cpuLoad: cpuLoad,
            processorCount: ProcessInfo.processInfo.processorCount,
            volumeFreeBytes: volume.free,
            volumeTotalBytes: volume.total,
            battery: Self.batterySnapshot(),
            externalDriveCount: Self.externalDriveCount(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            screenLocked: Self.isScreenLocked(),
            network: network,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    // MARK: - 内存压力

    /// `kern.memorystatus_vm_pressure_level`：1 正常、2 偏高、4 严重。
    private static func memoryPressureRawValue() -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0)
        return result == 0 ? value : nil
    }

    private static func memoryFacts() -> (used: UInt64, total: UInt64, compressor: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total, 0) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageBytes = UInt64(pageSize)
        let active = UInt64(stats.active_count) * pageBytes
        let wired = UInt64(stats.wire_count) * pageBytes
        let compressed = UInt64(stats.compressor_page_count) * pageBytes
        return (active + wired + compressed, total, compressed)
    }

    // MARK: - CPU（差值法）

    private func currentCPULoad() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let ticks = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { previousCPUTicks = ticks }
        guard let previous = previousCPUTicks else { return 0 }
        let userDelta = ticks.user &- previous.user
        let systemDelta = ticks.system &- previous.system
        let niceDelta = ticks.nice &- previous.nice
        let idleDelta = ticks.idle &- previous.idle
        let total = userDelta + systemDelta + niceDelta + idleDelta
        guard total > 0 else { return 0 }
        let busy = userDelta + systemDelta + niceDelta
        return min(1, Double(busy) / Double(total))
    }

    // MARK: - 卷容量（只读资源值，不枚举目录）

    private static func volumeFacts() -> (free: Int64, total: Int64) {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]
        guard let values = try? home.resourceValues(forKeys: keys) else { return (0, 0) }
        let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = Int64(values.volumeTotalCapacity ?? 0)
        return (free, total)
    }

    // MARK: - 电池与电源

    private static func batterySnapshot() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let minutes = description[kIOPSTimeToEmptyKey] as? Int
            let remaining = (minutes ?? 0) > 0 ? TimeInterval(minutes! * 60) : nil
            return BatterySnapshot(
                level: Double(current) / Double(maximum),
                isCharging: charging,
                timeRemaining: charging ? nil : remaining
            )
        }
        return nil
    }

    /// 只读取已挂载卷信息（getmntinfo），不枚举任何目录内容。
    private static func externalDriveCount() -> Int {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return 0 }
        var total = 0
        for index in 0..<Int(count) {
            let filesystem = mounts[index]
            let flags = filesystem.f_flags
            if (flags & UInt32(MNT_LOCAL)) != 0 { continue }
            total += 1
        }
        return total
    }

    // MARK: - 会话锁状态（只读会话字典，不触发任何用户界面）

    private static func isScreenLocked() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dictionary["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    // MARK: - 网络吞吐

    private func networkSnapshot(at date: Date) -> NetworkSnapshot {
        let counters = Self.networkCounters()
        defer {
            previousNetworkCounters = (counters.inbound, counters.outbound)
            previousNetworkDate = date
        }
        guard let previous = previousNetworkCounters, let previousDate = previousNetworkDate else {
            return NetworkSnapshot(
                isConnected: counters.connected,
                interfaceName: counters.name,
                uploadBytesPerSecond: 0,
                downloadBytesPerSecond: 0
            )
        }
        let elapsed = max(date.timeIntervalSince(previousDate), 0.001)
        let inbound = counters.inbound >= previous.inbound ? counters.inbound - previous.inbound : 0
        let outbound = counters.outbound >= previous.outbound ? counters.outbound - previous.outbound : 0
        return NetworkSnapshot(
            isConnected: counters.connected,
            interfaceName: counters.name,
            uploadBytesPerSecond: Double(outbound) / elapsed,
            downloadBytesPerSecond: Double(inbound) / elapsed
        )
    }

    private static func networkCounters() -> (inbound: UInt64, outbound: UInt64, connected: Bool, name: String) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0, false, "—") }
        defer { freeifaddrs(head) }
        var inbound: UInt64 = 0
        var outbound: UInt64 = 0
        var activeName = "—"
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer {
            defer { pointer = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback, let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.pointee.ifa_data else { continue }
            let networkData = data.assumingMemoryBound(to: if_data.self).pointee
            inbound &+= UInt64(networkData.ifi_ibytes)
            outbound &+= UInt64(networkData.ifi_obytes)
            if activeName == "—" { activeName = String(cString: interface.pointee.ifa_name) }
        }
        return (inbound, outbound, activeName != "—", activeName)
    }
}
