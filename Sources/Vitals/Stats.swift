import Foundation
import Darwin
import IOKit.ps

struct MemorySnapshot {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used ? total - used : 0 }
    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct TemperatureSnapshot {
    var cpu: Double?
    var cpuMax: Double?
    var ssd: Double?
    var battery: Double?
}

/// Low-level samplers for CPU load, memory, thermal sensors and network counters.
/// Buffers are kept between calls so a sampling tick does (almost) no allocation.
final class SystemSampler {
    struct CPUSample { var total = 0.0, user = 0.0, system = 0.0, cores: [Double] = [] }

    private static let cpuStates = Int(CPU_STATE_MAX)
    private var previousTicks: [UInt32] = []
    private var currentTicks: [UInt32] = []
    private let sensors = ThermalSensors()

    private var netBuffer = [UInt8](repeating: 0, count: 256)
    private var netInterfaces: [Int32] = []        // indexes of active en* interfaces, refreshed rarely
    private var netSamplesSinceScan = Int.max

    func cpu() -> CPUSample {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUSample() }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        let n = Int(count), S = Self.cpuStates
        currentTicks.removeAll(keepingCapacity: true)
        for i in 0..<(n * S) { currentTicks.append(UInt32(bitPattern: info[i])) }
        defer { swap(&previousTicks, &currentTicks) }
        guard previousTicks.count == currentTicks.count else { return CPUSample(cores: Array(repeating: 0, count: n)) }

        var cores = [Double](repeating: 0, count: n)
        var busyAll = 0.0, totalAll = 0.0, userAll = 0.0, sysAll = 0.0
        for c in 0..<n {
            let o = c * S
            func d(_ s: Int32) -> Double { Double(currentTicks[o + Int(s)] &- previousTicks[o + Int(s)]) }
            let user = d(CPU_STATE_USER), sys = d(CPU_STATE_SYSTEM), idle = d(CPU_STATE_IDLE), nice = d(CPU_STATE_NICE)
            let total = user + sys + idle + nice
            let busy = total - idle
            cores[c] = total > 0 ? busy / total : 0
            busyAll += busy; totalAll += total
            userAll += user + nice; sysAll += sys
        }
        guard totalAll > 0 else { return CPUSample(cores: cores) }
        return CPUSample(total: busyAll / totalAll, user: userAll / totalAll, system: sysAll / totalAll, cores: cores)
    }

    func memory() -> MemorySnapshot {
        var snap = MemorySnapshot()
        snap.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            snap.app = UInt64(stats.internal_page_count &- stats.purgeable_count) * page
            snap.wired = UInt64(stats.wire_count) * page
            snap.compressed = UInt64(stats.compressor_page_count) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snap.swapUsed = swap.xsu_used
            snap.swapTotal = swap.xsu_total
        }
        return snap
    }

    func temperatures() -> TemperatureSnapshot {
        let all = sensors.read()
        var cpuSum = 0.0, cpuN = 0.0, cpuMax: Double?, ssdSum = 0.0, ssdN = 0.0, batSum = 0.0, batN = 0.0
        for r in all {
            if r.name.contains("tdie") { cpuSum += r.celsius; cpuN += 1; cpuMax = max(cpuMax ?? 0, r.celsius) }
            else if r.name.hasPrefix("NAND") { ssdSum += r.celsius; ssdN += 1 }
            else if r.name.contains("battery") { batSum += r.celsius; batN += 1 }
        }
        return TemperatureSnapshot(cpu: cpuN > 0 ? cpuSum / cpuN : nil, cpuMax: cpuMax,
                                   ssd: ssdN > 0 ? ssdSum / ssdN : nil, battery: batN > 0 ? batSum / batN : nil)
    }

    /// Cumulative bytes received / sent over active physical interfaces (en*), as 64-bit counters
    /// (the routing-socket / getifaddrs counters wrap at 4 GB). The interface list is cached and
    /// only rescanned every ~30 samples, so a normal read is one `sysctl` per active interface.
    func network() -> (rx: UInt64, tx: UInt64) {
        if netSamplesSinceScan >= 30 { rescanInterfaces() }
        netSamplesSinceScan += 1
        var rx: UInt64 = 0, tx: UInt64 = 0
        for idx in netInterfaces {
            var mib: [Int32] = [CTL_NET, PF_LINK, 0, 2 /* IFMIB_IFDATA */, idx, 1 /* IFDATA_GENERAL */]
            var len = netBuffer.count
            guard sysctl(&mib, 6, &netBuffer, &len, nil, 0) == 0, len >= 132 else { continue }
            // struct ifmibdata: 52-byte header, then if_data64 (ibytes at +64, obytes at +72)
            netBuffer.withUnsafeBytes {
                rx += $0.loadUnaligned(fromByteOffset: 116, as: UInt64.self)
                tx += $0.loadUnaligned(fromByteOffset: 124, as: UInt64.self)
            }
        }
        return (rx, tx)
    }

    private func rescanInterfaces() {
        netSamplesSinceScan = 0
        netInterfaces.removeAll(keepingCapacity: true)
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        for idx in 1..<UInt32(64) where if_indextoname(idx, &name) != nil && String(cString: name).hasPrefix("en") {
            var mib: [Int32] = [CTL_NET, PF_LINK, 0, 2, Int32(idx), 1]
            var len = netBuffer.count
            guard sysctl(&mib, 6, &netBuffer, &len, nil, 0) == 0, len >= 132 else { continue }
            let flags = netBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }   // ifmd_flags
            if flags & UInt32(IFF_UP) != 0 { netInterfaces.append(Int32(idx)) }
        }
    }

    func invalidateNetworkInterfaces() { netSamplesSinceScan = Int.max }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

// MARK: - Observable slices
// One small model per metric, so a tick only redraws the views that show that metric
// (e.g. with the panel closed, only the menu bar number is invalidated).

@MainActor final class CPUModel: ObservableObject {
    @Published var usage = 0.0
    @Published var cores: [Double] = []
    @Published var user = 0.0
    @Published var system = 0.0
    @Published var load: (Double, Double, Double) = (0, 0, 0)
    @Published var history = [Double](repeating: 0, count: 60)
}

@MainActor final class MemoryModel: ObservableObject {
    @Published var snapshot = MemorySnapshot()
    @Published var history = [Double](repeating: 0, count: 60)
}

@MainActor final class ThermalModel: ObservableObject {
    @Published var temps = TemperatureSnapshot()
}

@MainActor final class NetworkModel: ObservableObject {
    @Published var down = 0.0          // bytes/s
    @Published var up = 0.0
    @Published var downHistory = [Double](repeating: 0, count: 60)
    @Published var upHistory = [Double](repeating: 0, count: 60)
    @Published var totalDown: UInt64 = 0
    @Published var totalUp: UInt64 = 0
    @Published var peakDown = 0.0
    @Published var peakUp = 0.0
}

/// Owns the samplers and the sampling schedule; holds no published state itself.
@MainActor
final class StatsModel: ObservableObject {
    let cpu = CPUModel()
    let memory = MemoryModel()
    let thermal = ThermalModel()
    let network = NetworkModel()

    let chip = SystemSampler.chipName()
    /// Apple Silicon: performance cores and efficiency cores (efficiency cores are enumerated first).
    let performanceCores = SystemSampler.sysctlInt("hw.perflevel0.logicalcpu") ?? ProcessInfo.processInfo.processorCount
    let efficiencyCores = SystemSampler.sysctlInt("hw.perflevel1.logicalcpu") ?? 0

    private let sampler = SystemSampler()
    private var timer: Timer?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?
    private var onBattery = false
    private var powerSource: CFRunLoopSource?

    var popoverOpen = false { didSet { if oldValue != popoverOpen { reschedule(sampleNow: popoverOpen) } } }
    var widgetOn = false { didSet { if oldValue != widgetOn { reschedule(sampleNow: widgetOn) } } }
    /// The Rede tab is selected; network counters are only read when someone can see them.
    var networkTabOpen = false { didSet { if oldValue != networkTabOpen { lastNet = nil; if networkTabOpen { tick() } } } }

    private var active: Bool { popoverOpen || widgetOn }
    private var needsNetwork: Bool { widgetOn || (popoverOpen && networkTabOpen) }

    init() {
        _ = sampler.cpu()
        tick()
        watchPower()
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reschedule(sampleNow: false) }
        }
        reschedule(sampleNow: false)
    }

    /// Sampling period: 2 s with the panel open, 3 s for the widget alone, 6 s for the menu bar number only;
    /// stretched on battery (x1.5) and in Low Power Mode (x2). Timers carry tolerance so wakeups coalesce.
    private func reschedule(sampleNow: Bool) {
        timer?.invalidate()
        var interval: TimeInterval = popoverOpen ? 2 : (widgetOn ? 3 : 6)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { interval *= 2 } else if onBattery { interval *= 1.5 }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval * 0.4
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if sampleNow { tick() }
    }

    private func tick() {
        let c = sampler.cpu()
        cpu.usage = c.total
        push(&cpu.history, c.total)
        guard active else { lastNet = nil; return }   // everything below is only read while visible
        cpu.cores = c.cores
        cpu.user = c.user
        cpu.system = c.system
        var l = (0.0, 0.0, 0.0)
        withUnsafeMutablePointer(to: &l) { $0.withMemoryRebound(to: Double.self, capacity: 3) { _ = getloadavg($0, 3) } }
        cpu.load = l

        let snap = sampler.memory()
        memory.snapshot = snap
        push(&memory.history, snap.fraction)
        thermal.temps = sampler.temperatures()
        if needsNetwork { updateNetwork() } else { lastNet = nil }
    }

    private func updateNetwork() {
        let n = sampler.network()
        let now = Date()
        network.totalDown = n.rx
        network.totalUp = n.tx
        if let last = lastNet, now > last.at, n.rx >= last.rx, n.tx >= last.tx {
            let dt = now.timeIntervalSince(last.at)
            network.down = Double(n.rx - last.rx) / dt
            network.up = Double(n.tx - last.tx) / dt
            network.peakDown = max(network.peakDown, network.down)
            network.peakUp = max(network.peakUp, network.up)
            push(&network.downHistory, network.down)
            push(&network.upHistory, network.up)
        } else if lastNet == nil {
            sampler.invalidateNetworkInterfaces()   // pick up interfaces that came up while we weren't looking
        }
        lastNet = (n.rx, n.tx, now)
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > 60 { a.removeFirst(a.count - 60) }
    }

    /// Notified by the system when AC / battery changes, so no polling is needed.
    private func watchPower() {
        func refresh(_ s: StatsModel) {
            let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            let type = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
            s.onBattery = type == kIOPSBatteryPowerValue
        }
        refresh(self)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let s = Unmanaged<StatsModel>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in
                let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
                s.onBattery = (IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String) == kIOPSBatteryPowerValue
                s.reschedule(sampleNow: false)
            }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }
    }
}
