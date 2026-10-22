import SwiftUI

enum Palette {
    static let cpu = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let memory = Color(red: 0.69, green: 0.32, blue: 0.87)
    static let temp = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let ok = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let hot = Color(red: 1.0, green: 0.27, blue: 0.23)

    static func temperature(_ c: Double) -> Color {
        c < 60 ? ok : (c < 80 ? temp : hot)
    }
}

func formatBytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
}

struct Ring: View {
    var value: Double
    var color: Color
    var title: String
    var text: String
    var icon: String
    var size: CGFloat = 78

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(color.opacity(0.16), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.001, min(value, 1)))
                    .stroke(
                        AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(min(value, 1), 0.05))),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                VStack(spacing: 1) {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                    Text(text).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            .frame(width: size, height: size)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var maxValue: Double = 1

    var body: some View {
        GeometryReader { g in
            let pts = points(in: g.size)
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: size.height - size.height * CGFloat(min(max(v / maxValue, 0), 1)))
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

struct SectionLabel: View {
    var text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

/// Visual-effect blur (vibrancy) behind a window's content.
struct Vibrancy: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Reports whether the hosting window is actually visible (the menu bar popover opened/closed).
struct VisibilityObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ObserverView()
        v.onChange = onChange
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { (v as? ObserverView)?.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            guard let w = window else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self, weak w] _ in
                self?.onChange?((w?.isVisible ?? false) && (w?.occlusionState.contains(.visible) ?? false))
            }
            onChange?(w.isVisible && w.occlusionState.contains(.visible))
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
