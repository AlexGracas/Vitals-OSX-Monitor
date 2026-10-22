import Foundation
import AppKit

struct BatteryDevice: Identifiable, Equatable, Codable {
    var id: String          // Bluetooth address
    var name: String
    var kind: String        // Keyboard, Mouse, Headphones...
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var charging = false
    var updatedAt: Date? = nil     // set only for devices polled sporadically (iPhone / iPad)

    var hasLevel: Bool { main != nil || left != nil || right != nil || caseLevel != nil }
    /// Lowest reported level, used for color / sorting.
    var lowest: Int? { [main, left, right, caseLevel].compactMap { $0 }.min() }

    var symbol: String {
        let n = name.lowercased(), k = kind.lowercased()
        if k == "iphone" { return "iphone" }
        if k == "ipad" { return "ipad" }
        if k == "watch" { return "applewatch" }
        if n.contains("airpods") { return n.contains("max") ? "airpodsmax" : "airpods" }
        if k.contains("keyboard") { return "keyboard" }
        if k.contains("mouse") { return "computermouse" }
        if k.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if k.contains("head") { return "headphones" }
        if k.contains("speaker") { return "hifispeaker" }
        if k.contains("game") { return "gamecontroller" }
        return "dot.radiowaves.left.and.right"
    }
}

/// Battery of connected Bluetooth devices (AirPods, mouse, keyboard...).
///
/// Power strategy: no persistent Bluetooth connection or scanning. A one-shot, ~80 ms
/// `system_profiler` read runs when the panel opens (if data is >60 s old) and then every
/// 15 min with a generous timer tolerance. In Low Power Mode background refreshes stop entirely.
@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var devices: [BatteryDevice] = []
    private var bluetooth: [BatteryDevice] = []
    private var mobile: [String: BatteryDevice] = [:]   // iPhone / iPad, kept between scans (and between launches)
    private var lastScanIncomplete = false
    private let ble = BLEBatteryReader()
    private var bleLevels: [String: Int] = [:]   // GATT battery by device name
    private var lastRefresh = Date.distantPast
    private var lastMobileScan = Date.distantPast
    private var timer: Timer?
    private var running = false
    private var scanning = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "mobileDevices"),
           let saved = try? JSONDecoder().decode([BatteryDevice].self, from: data) {
            mobile = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        }
        refresh()
        scanMobile()
        merge()
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.scanMobile() }
        let t = Timer(timeInterval: 20 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
                self.refresh()
                self.scanMobile()
            }
        }
        t.tolerance = 4 * 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 60 { refresh() }
        let age = Date().timeIntervalSince(lastMobileScan)
        // Discovery over Wi-Fi is intermittent: if the last window missed a known device, try again sooner.
        if age > 5 * 60 || (lastScanIncomplete && age > 45) { scanMobile() }
    }

    /// iPhone / iPad: short MobileDevice listening window, then fully idle until the next one.
    func scanMobile() {
        guard !scanning else { return }
        scanning = true
        lastMobileScan = Date()
        Task.detached(priority: .background) {
            let found = MobileDeviceReader.scan(window: 25)
            await MainActor.run {
                self.scanning = false
                self.lastScanIncomplete = found.count < max(self.mobile.count, 1)
                for d in found { self.mobile[d.id] = d }
                if let data = try? JSONEncoder().encode(Array(self.mobile.values)) { UserDefaults.standard.set(data, forKey: "mobileDevices") }
                self.merge()
            }
        }
    }

    private func merge() {
        var bt = bluetooth
        for i in bt.indices where !bt[i].hasLevel { bt[i].main = bleLevels[bt[i].name] }
        let all = (bt + mobile.values).sorted { $0.name < $1.name }
        if devices != all { devices = all }
    }

    func refresh() {
        guard !running else { return }
        running = true
        lastRefresh = Date()
        Task.detached(priority: .background) {
            let result = Self.read()
            await MainActor.run {
                self.running = false
                self.bluetooth = result
                self.merge()
                if result.contains(where: { !$0.hasLevel }) || result.isEmpty {
                    self.ble.read { levels in
                        self.bleLevels = levels
                        self.merge()
                    }
                }
            }
        }
    }
    nonisolated private static func read() -> [BatteryDevice] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bt = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = bt["device_connected"] as? [[String: [String: Any]]] else { return [] }

        func pct(_ v: Any?) -> Int? {
            guard let s = v as? String else { return nil }
            return Int(s.filter(\.isNumber))
        }
        var out: [BatteryDevice] = []
        for entry in connected {
            for (name, info) in entry {
                out.append(BatteryDevice(
                    id: (info["device_address"] as? String) ?? name, name: name,
                    kind: (info["device_minorType"] as? String) ?? "",
                    main: pct(info["device_batteryLevelMain"]),
                    left: pct(info["device_batteryLevelLeft"]),
                    right: pct(info["device_batteryLevelRight"]),
                    caseLevel: pct(info["device_batteryLevelCase"])))
            }
        }
        return out.sorted { $0.name < $1.name }
    }
}

