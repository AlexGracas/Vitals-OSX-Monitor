import AppKit
import Foundation

struct DisplayControl: Identifiable {
    let id: CGDirectDisplayID
    var name: String
    var detail: String
    var brightness: Double      // 0...1
    var contrast: Double
    var volume: Double
    var canRead: Bool           // false = monitor accepts commands but cannot report state
    var software: Bool          // true = DDC/CI unavailable; brightness is applied through the gamma table
    fileprivate let channel: DDCChannel?
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var monitors: [DisplayControl] = []
    private var pending: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(delay: 1.5) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(delay: 2) }
        }
        scheduleRefresh(delay: 0)
    }

    /// Gamma tables are reset by macOS on reconfiguration/wake, so software brightness is re-applied.
    func reapplySoftware() {
        for m in monitors where m.software { applyGamma(m.brightness, to: m.id) }
    }

    private func applyGamma(_ b: Double, to id: CGDirectDisplayID) {
        let g = Float(max(0.05, b))
        CGSetDisplayTransferByFormula(id, 0, g, 1, 0, g, 1, 0, g, 1)
    }

    func scheduleRefresh(delay: Double) {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        let screens = NSScreen.screens.compactMap { s -> (CGDirectDisplayID, NSScreen)? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            return CGDisplayIsBuiltin(id) == 0 ? (id, s) : nil
        }
        guard !screens.isEmpty else { monitors = []; return }

        let known = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
        let infos = screens.map { (id: $0.0, name: $0.1.localizedName, detail: Self.detail(id: $0.0, screen: $0.1)) }

        let result: [DisplayControl] = await Task.detached(priority: .userInitiated) {
            var channels = DDCDiscovery.channels()
            var out: [DisplayControl] = []
            for info in infos {
                let names = infos.map { $0.name.lowercased() }
                let idx = channels.firstIndex { ($0.productName ?? "").lowercased() == info.name.lowercased() }
                    ?? channels.firstIndex { ch in !names.contains((ch.productName ?? "").lowercased()) }
                let ch = idx.map { channels.remove(at: $0) }
                let prev = await known[info.id]

                // No DDC/CI response -> fall back to software (gamma) brightness.
                guard let ch, ch.probe() else {
                    let saved = UserDefaults.standard.object(forKey: "soft.\(info.name)") as? Double
                    out.append(DisplayControl(id: info.id, name: info.name, detail: info.detail,
                                              brightness: prev?.brightness ?? saved ?? 1.0, contrast: 0, volume: 0,
                                              canRead: false, software: true, channel: nil))
                    continue
                }
                let b = ch.get(.brightness)
                let c = b == nil ? nil : ch.get(.contrast)
                let v = b == nil ? nil : ch.get(.volume)
                func frac(_ r: (current: Int, max: Int)?, _ fallback: Double) -> Double {
                    guard let r, r.max > 0 else { return fallback }
                    return Double(r.current) / Double(r.max)
                }
                out.append(DisplayControl(
                    id: info.id, name: info.name, detail: info.detail,
                    brightness: frac(b, prev?.brightness ?? 0.5),
                    contrast: frac(c, prev?.contrast ?? 0.5),
                    volume: frac(v, prev?.volume ?? 0.5),
                    canRead: b != nil, software: false, channel: ch))
            }
            return out
        }.value
        monitors = result
        reapplySoftware()
    }

    private static func detail(id: CGDirectDisplayID, screen: NSScreen) -> String {
        let w = Int(Double(screen.frame.width) * screen.backingScaleFactor)
        let h = Int(Double(screen.frame.height) * screen.backingScaleFactor)
        let hz = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return hz > 0 ? "\(w)×\(h) · \(Int(hz.rounded())) Hz" : "\(w)×\(h)"
    }

    func set(_ code: VCP, _ value: Double, on id: CGDirectDisplayID) {
        guard let i = monitors.firstIndex(where: { $0.id == id }) else { return }
        switch code {
        case .brightness: monitors[i].brightness = value
        case .contrast: monitors[i].contrast = value
        case .volume: monitors[i].volume = value
        }
        if monitors[i].software {
            applyGamma(value, to: id)
            UserDefaults.standard.set(value, forKey: "soft.\(monitors[i].name)")
            return
        }
        guard let channel = monitors[i].channel else { return }
        let key = "\(id)-\(code.rawValue)"
        pending[key]?.cancel()
        pending[key] = Task {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            channel.set(code, Int((value * 100).rounded()))
        }
    }
}
