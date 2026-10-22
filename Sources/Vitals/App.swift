import SwiftUI
import AppKit

/// Borderless panel that sits on the desktop, above the wallpaper but below normal windows.
@MainActor
final class WidgetController: ObservableObject {
    @Published private(set) var isVisible = UserDefaults.standard.bool(forKey: "widgetVisible")
    private var panel: NSPanel?
    private let stats: StatsModel

    init(stats: StatsModel) {
        self.stats = stats
        stats.widgetOn = isVisible
        if isVisible { DispatchQueue.main.async { self.show() } }
    }

    func setVisible(_ on: Bool) {
        isVisible = on
        stats.widgetOn = on
        UserDefaults.standard.set(on, forKey: "widgetVisible")
        on ? show() : panel?.orderOut(nil)
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            let host = NSHostingView(rootView: WidgetView()
                .environmentObject(stats.cpu).environmentObject(stats.memory)
                .environmentObject(stats.thermal).environmentObject(stats.network))
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 170)
            p.contentView = host
            if !p.setFrameUsingName("VitalsWidget"), let s = NSScreen.main {
                p.setFrameOrigin(NSPoint(x: s.visibleFrame.maxX - 300, y: s.visibleFrame.maxY - 190))
            }
            p.setFrameAutosaveName("VitalsWidget")
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

@main
struct VitalsApp: App {
    @StateObject private var stats: StatsModel
    @StateObject private var store = MonitorStore()
    @StateObject private var widget: WidgetController
    @StateObject private var devices = DevicesModel()
    @StateObject private var storage = StorageModel()

    init() {
        let s = StatsModel()
        _stats = StateObject(wrappedValue: s)
        _widget = StateObject(wrappedValue: WidgetController(stats: s))
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(stats)
                .environmentObject(stats.cpu)
                .environmentObject(stats.memory)
                .environmentObject(stats.thermal)
                .environmentObject(stats.network)
                .environmentObject(store)
                .environmentObject(widget)
                .environmentObject(devices)
                .environmentObject(storage)
        } label: {
            MenuLabel(cpu: stats.cpu)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar label; observes only the CPU model so it is the only thing redrawn while the panel is closed.
struct MenuLabel: View {
    @ObservedObject var cpu: CPUModel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.67percent")
            Text("\(Int(cpu.usage * 100))%").monospacedDigit()
        }
    }
}
