import SwiftUI

enum Tab: String, CaseIterable { case system = "Sistema", network = "Rede", storage = "Disco", monitors = "Monitores", devices = "Dispositivos" }

struct PopoverView: View {
    @EnvironmentObject var stats: StatsModel
    @EnvironmentObject var store: MonitorStore
    @EnvironmentObject var widget: WidgetController
    @EnvironmentObject var devices: DevicesModel
    @State private var tab: Tab = .system

    /// Tabs appear only when they have something to show (monitors connected / Bluetooth devices connected).
    private var tabs: [Tab] {
        var t: [Tab] = [.system, .network, .storage]
        if !store.monitors.isEmpty { t.append(.monitors) }
        if !devices.devices.isEmpty { t.append(.devices) }
        return t
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            if tabs.count > 1 {
                Picker("", selection: $tab) {
                    ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if tab == .monitors && tabs.contains(.monitors) {
                        ForEach(store.monitors) { MonitorCard(monitor: $0) }
                    } else if tab == .network {
                        NetworkView()
                    } else if tab == .storage {
                        StorageView()
                    } else if tab == .devices && tabs.contains(.devices) {
                        ForEach(devices.devices) { DeviceCard(device: $0) }
                    } else {
                        SystemView()
                    }
                }
            }
            .frame(height: 470)
            footer
        }
        .padding(16)
        .frame(width: 360)
        .onChange(of: tabs) { _, t in if !t.contains(tab) { tab = .system } }
        .background(VisibilityObserver { visible in
            stats.popoverOpen = visible
            if visible { devices.refreshIfStale() }
        })
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.cpu, Palette.memory], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Vitals").font(.system(size: 14, weight: .semibold))
                Text(stats.chip).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { widget.isVisible }, set: { widget.setVisible($0) })) {
                Label("Widget na mesa", systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch).controlSize(.small)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                HStack(spacing: 4) { Text("Sair"); Text("⌘Q").foregroundStyle(.tertiary) }.font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }
}

struct SystemView: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                CPURing()
                MemoryRing()
                TempRing()
            }
            .padding(.vertical, 4)
            CPUCard()
            MemoryCard()
            TempsCard()
        }
    }
}

struct CPURing: View {
    @EnvironmentObject var cpu: CPUModel
    var size: CGFloat = 78
    var body: some View {
        Ring(value: cpu.usage, color: Palette.cpu, title: "CPU", text: "\(Int(cpu.usage * 100))%", icon: "cpu", size: size)
    }
}

struct MemoryRing: View {
    @EnvironmentObject var memory: MemoryModel
    var size: CGFloat = 78
    var body: some View {
        let f = memory.snapshot.fraction
        Ring(value: f, color: Palette.memory, title: "Memória", text: "\(Int(f * 100))%", icon: "memorychip", size: size)
    }
}

struct TempRing: View {
    @EnvironmentObject var thermal: ThermalModel
    var size: CGFloat = 78
    var body: some View {
        let t = thermal.temps.cpu
        Ring(value: min((t ?? 0) / 100, 1), color: Palette.temperature(t ?? 0), title: "Temp.",
             text: t.map { "\(Int($0))°" } ?? "—", icon: "thermometer.medium", size: size)
    }
}

struct MemoryCard: View {
    @EnvironmentObject var memory: MemoryModel

    var body: some View {
        let m = memory.snapshot
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Memória", trailing: "\(formatBytes(m.used)) de \(formatBytes(m.total))")
                MemoryBar(m: m)
                HStack(spacing: 12) {
                    legend("App", m.app, Palette.memory)
                    legend("Wired", m.wired, Palette.temp)
                    legend("Comprimida", m.compressed, Palette.cpu)
                }
                if m.swapTotal > 0 {
                    HStack {
                        Text("Swap").foregroundStyle(.secondary)
                        Spacer()
                        Text(formatBytes(m.swapUsed)).monospacedDigit()
                    }.font(.system(size: 11))
                }
            }
        }
    }

    private func legend(_ name: String, _ bytes: UInt64, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(formatBytes(bytes)).font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
        }
    }
}

struct TempsCard: View {
    @EnvironmentObject var thermal: ThermalModel

    var body: some View {
        let t = thermal.temps
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Temperaturas")
                TempRow(name: "CPU", icon: "cpu", value: t.cpu)
                TempRow(name: "CPU (pico)", icon: "flame", value: t.cpuMax)
                TempRow(name: "SSD", icon: "internaldrive", value: t.ssd)
                TempRow(name: "Bateria", icon: "battery.75percent", value: t.battery)
            }
        }
    }
}

struct MemoryBar: View {
    var m: MemorySnapshot
    var body: some View {
        GeometryReader { g in
            let t = Double(max(m.total, 1))
            HStack(spacing: 2) {
                seg(Palette.memory, Double(m.app) / t, g.size.width)
                seg(Palette.temp, Double(m.wired) / t, g.size.width)
                seg(Palette.cpu, Double(m.compressed) / t, g.size.width)
                Spacer(minLength: 0)
            }
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.4), value: m.used)
    }
    private func seg(_ c: Color, _ f: Double, _ w: CGFloat) -> some View {
        Rectangle().fill(c).frame(width: max(0, w * f - 2))
    }
}

struct TempRow: View {
    var name: String
    var icon: String
    var value: Double?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(name).font(.system(size: 12))
            Spacer()
            if let v = value {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Palette.temperature(v)).frame(width: g.size.width * min(v / 100, 1))
                    }
                }
                .frame(width: 70, height: 5)
                Text(String(format: "%.0f°C", v)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 44, alignment: .trailing)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}

struct MonitorCard: View {
    @EnvironmentObject var store: MonitorStore
    var monitor: DisplayControl

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "display").font(.system(size: 18)).foregroundStyle(Palette.cpu)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(monitor.name).font(.system(size: 13, weight: .semibold))
                        Text(monitor.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if monitor.software {
                        Text("Software").font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Palette.temp.opacity(0.2))).foregroundStyle(Palette.temp)
                    } else {
                        Circle().fill(Palette.ok).frame(width: 7, height: 7)
                    }
                }
                slider("sun.max.fill", "Brilho", .brightness, monitor.brightness)
                if !monitor.software {
                    slider("circle.lefthalf.filled", "Contraste", .contrast, monitor.contrast)
                    slider("speaker.wave.2.fill", "Volume", .volume, monitor.volume)
                }
                HStack(spacing: 6) {
                    ForEach([("Noite", 0.2), ("Baixo", 0.4), ("Médio", 0.7), ("Máx", 1.0)], id: \.0) { name, v in
                        Button(name) { store.set(.brightness, v, on: monitor.id) }
                            .buttonStyle(PresetStyle(active: abs(monitor.brightness - v) < 0.03))
                    }
                }
                if monitor.software {
                    Text("Este monitor não responde a DDC/CI. O brilho é ajustado por software (gama). Para controle real, ative \"DDC/CI\" no menu OSD do monitor.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if !monitor.canRead {
                    Text("Este monitor não informa o estado atual; os valores exibidos são estimados.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func slider(_ icon: String, _ label: String, _ code: VCP, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(label, systemImage: icon).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: { store.set(code, $0, on: monitor.id) }), in: 0...1)
                .controlSize(.small)
        }
    }
}

struct PresetStyle: ButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Palette.cpu.opacity(0.9) : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .foregroundStyle(active ? Color.white : Color.primary)
            .animation(.easeOut(duration: 0.15), value: active)
    }
}

/// Compact desktop widget content.
struct WidgetView: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                CPURing(size: 66)
                MemoryRing(size: 66)
                TempRing(size: 66)
            }
            WidgetNetwork().frame(height: 28)
        }
        .padding(16)
        .frame(width: 280, height: 170)
        .background(Vibrancy(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

struct WidgetNetwork: View {
    @EnvironmentObject var net: NetworkModel

    var body: some View {
        HStack(spacing: 16) {
            label("arrow.down", net.down, Palette.ok)
            label("arrow.up", net.up, Palette.temp)
        }
    }

    private func label(_ icon: String, _ rate: Double, _ color: Color) -> some View {
        let r = formatRate(rate)
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text("\(r.value) \(r.unit)").font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

func formatRate(_ bytesPerSec: Double) -> (value: String, unit: String) {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var v = max(bytesPerSec, 0), i = 0
    while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
    return (i == 0 ? String(format: "%.0f", v) : (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)), units[i])
}

func formatTotal(_ b: UInt64) -> String {
    let d = Double(b)
    if d >= 1e12 { return String(format: "%.2f TB", d / 1e12) }
    if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
    return String(format: "%.0f MB", d / 1e6)
}

struct CPUCard: View {
    @EnvironmentObject var stats: StatsModel
    @EnvironmentObject var cpu: CPUModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Processador")
                    Spacer()
                    Text(stats.efficiencyCores > 0 ? "\(stats.performanceCores)P + \(stats.efficiencyCores)E" : "\(cpu.cores.count) núcleos")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int((cpu.usage * 100).rounded()))").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Carga média").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(String(format: "%.2f  %.2f  %.2f", cpu.load.0, cpu.load.1, cpu.load.2))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                }

                ZStack {
                    VStack(spacing: 0) {
                        ForEach(0..<4) { i in
                            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
                            if i < 3 { Spacer() }
                        }
                    }
                    Sparkline(values: cpu.history, color: Palette.cpu)
                }
                .frame(height: 56)

                // user / system split
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            Capsule().fill(Palette.cpu).frame(width: max(0, g.size.width * cpu.user))
                            Capsule().fill(Palette.hot).frame(width: max(0, g.size.width * cpu.system))
                            Spacer(minLength: 0)
                        }
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .frame(height: 6)
                    .animation(.easeOut(duration: 0.3), value: cpu.user)
                    HStack(spacing: 14) {
                        key("Usuário", cpu.user, Palette.cpu)
                        key("Sistema", cpu.system, Palette.hot)
                        key("Ocioso", max(0, 1 - cpu.usage), Color.primary.opacity(0.25))
                    }
                }

                // per-core, grouped by cluster
                let eCount = min(stats.efficiencyCores, cpu.cores.count)
                let efficiency = Array(cpu.cores.prefix(eCount))
                let performance = Array(cpu.cores.dropFirst(eCount))
                HStack(alignment: .top, spacing: 14) {
                    if !efficiency.isEmpty { cluster("Eficiência", efficiency, Palette.ok) }
                    cluster(efficiency.isEmpty ? "Núcleos" : "Performance", performance, Palette.cpu)
                }
            }
        }
    }

    private func key(_ name: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
            Text("\(Int((v * 100).rounded()))%").font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }

    private func cluster(_ title: String, _ values: [Double], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.tertiary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.15))
                            RoundedRectangle(cornerRadius: 2).fill(color).frame(height: max(2, 34 * v))
                        }
                        .frame(height: 34)
                        Text("\(Int((v * 100).rounded()))").font(.system(size: 8)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: values)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NetworkView: View {
    @EnvironmentObject var stats: StatsModel
    @EnvironmentObject var net: NetworkModel

    var body: some View {
        content
            .onAppear { stats.networkTabOpen = true }
            .onDisappear { stats.networkTabOpen = false }
    }

    private var content: some View {
        VStack(spacing: 12) {
            rateCard("Download", "arrow.down.circle.fill", net.down, net.downHistory, Palette.ok, peak: net.peakDown)
            rateCard("Upload", "arrow.up.circle.fill", net.up, net.upHistory, Palette.temp, peak: net.peakUp)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Tráfego total", trailing: "desde o boot")
                    row("arrow.down", "Recebido", formatTotal(net.totalDown), Palette.ok)
                    row("arrow.up", "Enviado", formatTotal(net.totalUp), Palette.temp)
                }
            }
        }
    }

    private func rateCard(_ title: String, _ icon: String, _ rate: Double, _ history: [Double], _ color: Color, peak: Double) -> some View {
        let r = formatRate(rate)
        let top = max(history.max() ?? 0, 10_000)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(title, systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                    Spacer()
                    Text("pico " + formatRate(peak).value + " " + formatRate(peak).unit)
                        .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(r.value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(r.unit).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                Sparkline(values: history, color: color, maxValue: top).frame(height: 48)
            }
        }
    }

    private func row(_ icon: String, _ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).frame(width: 16)
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }
}

struct DeviceCard: View {
    var device: BatteryDevice

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: device.symbol).font(.system(size: 20)).foregroundStyle(Palette.cpu).frame(width: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name).font(.system(size: 13, weight: .semibold))
                    if device.left != nil || device.right != nil || device.caseLevel != nil {
                        HStack(spacing: 14) {
                            part("L", device.left); part("R", device.right); part("Estojo", device.caseLevel)
                        }
                    } else if let m = device.main {
                        BatteryBar(level: m)
                    } else {
                        Text("Sem leitura de bateria").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                if let m = device.main {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 2) {
                            if device.charging { Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(Palette.ok) }
                            Text("\(m)%").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        if let t = device.updatedAt, Date().timeIntervalSince(t) > 120 {
                            Text(t, style: .relative).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func part(_ label: String, _ v: Int?) -> some View {
        if let v {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(label) \(v)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                BatteryBar(level: v).frame(width: 52)
            }
        }
    }
}

struct BatteryBar: View {
    var level: Int
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(level <= 15 ? Palette.hot : (level <= 30 ? Palette.temp : Palette.ok))
                    .frame(width: g.size.width * CGFloat(min(max(level, 0), 100)) / 100)
            }
        }
        .frame(height: 6)
    }
}
