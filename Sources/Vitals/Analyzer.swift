import SwiftUI
import AppKit

/// One ring segment of the sunburst. Angles are in radians, 0 at the top, growing clockwise.
struct Arc {
    let node: FileNode
    let depth: Int
    let a0: Double
    let a1: Double
    let color: Color
}

@MainActor
final class AnalyzerModel: ObservableObject {
    nonisolated static let maxDepth = 6

    @Published private(set) var root: FileNode?
    @Published private(set) var focus: FileNode?
    @Published var selected: FileNode?
    @Published var hovered: FileNode?
    @Published private(set) var arcs: [Arc] = []
    @Published private(set) var arcsVersion = 0
    @Published private(set) var largestFiles: [FileNode] = []
    @Published private(set) var scanning = false
    @Published private(set) var partial = false
    @Published private(set) var scanStatus: (files: Int, bytes: Int64, current: String) = (0, 0, "")
    @Published private(set) var scanDuration: TimeInterval = 0
    @Published private(set) var volume = VolumeInfo.read()
    @Published var error: String?
    @Published private(set) var rootURL: URL

    private(set) var colors: [ObjectIdentifier: Color] = [:]
    private var backStack: [FileNode] = []
    private var progress: ScanProgress?
    private var poll: Timer?

    init(url: URL) { rootURL = url }

    var canGoBack: Bool { !backStack.isEmpty }

    func scan(_ url: URL) {
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        rootURL = url
        root = nil; focus = nil; selected = nil; hovered = nil; arcs = []; largestFiles = []; backStack = []
        scanning = true; partial = false
        scanStatus = (0, 0, url.path)
        let started = Date()
        poll?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, self.progress === p { self.scanStatus = p.snapshot } }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = DiskScanner.scan(url, progress: p)
            DispatchQueue.main.async {
                guard self.progress === p else { return }
                self.poll?.invalidate()
                self.scanning = false
                self.partial = p.cancelled
                self.scanDuration = Date().timeIntervalSince(started)
                self.volume = VolumeInfo.read(url)
                self.root = tree
                self.setFocus(tree, remember: false)
            }
        }
    }

    func cancel() { progress?.cancel() }

    func stop() {
        progress?.cancel()
        progress = nil
        poll?.invalidate()
    }

    func setFocus(_ n: FileNode, remember: Bool = true) {
        guard n.isDir else { selected = n; return }
        if remember, let f = focus, f !== n { backStack.append(f) }
        focus = n
        hovered = nil
        if let s = selected, !n.contains(s) || s === n { selected = nil }
        relayout()
    }

    func goBack() { if let n = backStack.popLast() { setFocus(n, remember: false) } }
    func goUp() { if let p = focus?.parent { setFocus(p) } }

    func color(_ n: FileNode) -> Color { colors[ObjectIdentifier(n)] ?? Color.gray.opacity(0.5) }

    private func relayout() {
        guard let focus else { arcs = []; return }
        var out: [Arc] = []
        var map: [ObjectIdentifier: Color] = [:]
        func go(_ n: FileNode, _ depth: Int, _ a0: Double, _ a1: Double, _ hue: Double?) {
            guard depth <= Self.maxDepth, n.size > 0 else { return }
            var a = a0
            for c in n.children {
                let span = (a1 - a0) * Double(c.size) / Double(n.size)
                if span < 0.004 { break }        // children are sorted by size
                let h = hue ?? ((a + span / 2) / (2 * .pi) * 0.92)
                let color: Color
                if c.isAggregate {
                    color = Color(white: 0.55, opacity: 0.6)
                } else if c.isDir {
                    color = Color(hue: h, saturation: max(0.25, 0.72 - 0.08 * Double(depth - 1)), brightness: min(1, 0.86 + 0.025 * Double(depth)))
                } else {
                    color = Color(hue: h, saturation: 0.22, brightness: 0.82)
                }
                out.append(Arc(node: c, depth: depth, a0: a, a1: a + span, color: color))
                map[ObjectIdentifier(c)] = color
                if c.isDir { go(c, depth + 1, a, a + span, h) }
                a += span
            }
        }
        go(focus, 1, 0, 2 * .pi, nil)
        arcs = out
        colors = map
        arcsVersion += 1

        var files: [FileNode] = []
        func collect(_ n: FileNode) {
            for c in n.children { if c.isDir { collect(c) } else if !c.isAggregate { files.append(c) } }
        }
        collect(focus)
        largestFiles = Array(files.sorted { $0.size > $1.size }.prefix(12))
    }

    func trash(_ n: FileNode) {
        guard !n.isAggregate, n !== root else { return }
        do {
            try FileManager.default.trashItem(at: n.url, resultingItemURL: nil)
        } catch {
            self.error = error.localizedDescription
            return
        }
        guard let parent = n.parent else { return }
        parent.children.removeAll { $0 === n }
        var p: FileNode? = parent
        while let c = p {
            c.size -= n.size
            c.items -= n.items
            c.children.sort { $0.size > $1.size }
            p = c.parent
        }
        if selected.map(n.contains) == true { selected = nil }
        if let f = focus, n.contains(f) { setFocus(parent, remember: false) } else { relayout() }
        backStack.removeAll { n.contains($0) }
        volume = VolumeInfo.read(rootURL)
    }
}

/// Owns the detailed-analysis window. The app becomes a regular (Dock) app while it is open, and
/// the scanned tree is released when it closes.
@MainActor
final class AnalyzerWindow: NSObject, NSWindowDelegate {
    static let shared = AnalyzerWindow()
    private var window: NSWindow?
    private var model: AnalyzerModel?

    func open(_ url: URL) {
        if window == nil {
            let m = AnalyzerModel(url: url)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Análise de Disco"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 960, height: 600)
            w.contentView = NSHostingView(rootView: AnalyzerView().environmentObject(m))
            w.delegate = self
            if !w.setFrameUsingName("VitalsAnalyzer") { w.center() }
            w.setFrameAutosaveName("VitalsAnalyzer")
            window = w
            model = m
            m.scan(url)
        } else if let m = model, m.rootURL != url {
            m.scan(url)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        window?.contentView = nil
        window?.delegate = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Views

struct AnalyzerView: View {
    @EnvironmentObject var model: AnalyzerModel

    var body: some View {
        VStack(spacing: 0) {
            AnalyzerToolbar()
                .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 10)
            Divider()
            if model.scanning {
                ScanningView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.focus != nil {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        SunburstView().padding(20)
                        HoverCaption().padding(.horizontal, 20).padding(.bottom, 14)
                    }
                    .frame(minWidth: 380, maxWidth: .infinity)
                    Divider()
                    ChildrenList().frame(width: 330)
                    Divider()
                    InspectorPane().frame(width: 280)
                }
            } else {
                Text("Nada para mostrar").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            StatusBar().padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .alert("Não foi possível mover para o Lixo", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct AnalyzerToolbar: View {
    @EnvironmentObject var model: AnalyzerModel

    var body: some View {
        HStack(spacing: 10) {
            ControlGroup {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack).help("Voltar")
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(model.focus?.parent == nil).help("Pasta acima")
            }
            .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array((model.focus?.path ?? []).enumerated()), id: \.element.id) { i, n in
                        if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                        Button { model.setFocus(n) } label: {
                            HStack(spacing: 4) {
                                if i == 0 { Image(systemName: "internaldrive").foregroundStyle(Palette.cpu) }
                                Text(n.name).lineLimit(1)
                            }
                            .font(.system(size: 12, weight: n === model.focus ? .semibold : .regular))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(n === model.focus ? Color.primary.opacity(0.08) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 8)
            Menu {
                let home = FileManager.default.homeDirectoryForCurrentUser
                Button("Pasta pessoal") { model.scan(home) }
                Button("Macintosh HD (dados)") {
                    let data = URL(fileURLWithPath: "/System/Volumes/Data")
                    model.scan(FileManager.default.fileExists(atPath: data.path) ? data : URL(fileURLWithPath: "/"))
                }
                Button("Aplicativos") { model.scan(URL(fileURLWithPath: "/Applications")) }
                Button("Biblioteca") { model.scan(home.appendingPathComponent("Library")) }
                Divider()
                Button("Escolher pasta…") { chooseFolder() }
            } label: {
                Label("Local", systemImage: "folder")
            }
            .fixedSize()
            Button { model.scan(model.rootURL) } label: { Label("Reanalisar", systemImage: "arrow.clockwise") }
                .disabled(model.scanning)
        }
        .controlSize(.regular)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Analisar"
        if p.runModal() == .OK, let u = p.url { model.scan(u) }
    }
}

struct ScanningView: View {
    @EnvironmentObject var model: AnalyzerModel

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Analisando \(model.rootURL.path)").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 24) {
                stat("Arquivos", model.scanStatus.files.formatted())
                stat("Tamanho", formatSize(model.scanStatus.bytes))
            }
            Text(model.scanStatus.current).font(.system(size: 11)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            Button("Parar e mostrar parcial") { model.cancel() }.controlSize(.regular)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: Sunburst

private struct RingGeometry {
    let center: CGPoint
    let r0: CGFloat
    let width: CGFloat

    init(size: CGSize) {
        let R = min(size.width, size.height) / 2 - 4
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        r0 = R * 0.22
        width = (R - r0) / CGFloat(AnalyzerModel.maxDepth)
    }

    func point(_ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: center.x + r * CGFloat(sin(a)), y: center.y - r * CGFloat(cos(a)))
    }

    func path(_ arc: Arc) -> Path {
        let r1 = r0 + CGFloat(arc.depth - 1) * width, r2 = r1 + width
        let steps = max(2, Int((arc.a1 - arc.a0) * Double(r2) / 3))
        return Path { p in
            for i in 0...steps { let a = arc.a0 + (arc.a1 - arc.a0) * Double(i) / Double(steps)
                i == 0 ? p.move(to: point(r2, a)) : p.addLine(to: point(r2, a)) }
            for i in (0...steps).reversed() { p.addLine(to: point(r1, arc.a0 + (arc.a1 - arc.a0) * Double(i) / Double(steps))) }
            p.closeSubpath()
        }
    }

    /// nil = outside, .some(nil) = centre disc, .some(arc) = a segment.
    func hit(_ p: CGPoint, in arcs: [Arc]) -> Arc?? {
        let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
        let r = CGFloat((dx * dx + dy * dy).squareRoot())
        if r < r0 { return .some(nil) }
        let depth = Int((r - r0) / width) + 1
        guard depth <= AnalyzerModel.maxDepth else { return nil }
        var a = atan2(dx, -dy)
        if a < 0 { a += 2 * .pi }
        guard let arc = arcs.first(where: { $0.depth == depth && a >= $0.a0 && a < $0.a1 }) else { return nil }
        return .some(arc)
    }
}

/// The static rings; only redrawn when the layout changes, not on hover.
private struct SunburstRings: View, Equatable {
    let arcs: [Arc]
    let version: Int
    static func == (a: Self, b: Self) -> Bool { a.version == b.version }

    var body: some View {
        Canvas { ctx, size in
            let g = RingGeometry(size: size)
            let gap = Color(nsColor: .windowBackgroundColor)
            for arc in arcs {
                let p = g.path(arc)
                ctx.fill(p, with: .color(arc.color))
                ctx.stroke(p, with: .color(gap), lineWidth: 0.8)
            }
        }
    }
}

struct SunburstView: View {
    @EnvironmentObject var model: AnalyzerModel

    var body: some View {
        GeometryReader { geo in
            let g = RingGeometry(size: geo.size)
            ZStack {
                SunburstRings(arcs: model.arcs, version: model.arcsVersion).equatable()
                Canvas { ctx, _ in
                    for n in [model.selected, model.hovered].compactMap({ $0 }) {
                        for arc in model.arcs where arc.node === n || n.contains(arc.node) {
                            ctx.fill(g.path(arc), with: .color(.white.opacity(n === model.hovered ? 0.28 : 0.18)))
                        }
                        if let arc = model.arcs.first(where: { $0.node === n }) {
                            ctx.stroke(g.path(arc), with: .color(.primary.opacity(0.85)), lineWidth: 1.6)
                        }
                    }
                }
                .allowsHitTesting(false)
                centerLabel(g)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let hit = g.hit(p, in: model.arcs)
                    let n: FileNode? = hit.flatMap { $0?.node }
                    if n !== model.hovered { model.hovered = n }
                    if case .some(nil) = hit { NSCursor.pointingHand.set() } else if n?.isDir == true { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                case .ended:
                    model.hovered = nil
                    NSCursor.arrow.set()
                }
            }
            .gesture(SpatialTapGesture().onEnded { v in
                switch g.hit(v.location, in: model.arcs) {
                case .some(nil): model.goUp()
                case .some(let arc?):
                    if arc.node.isDir { model.setFocus(arc.node); model.selected = nil } else { model.selected = arc.node }
                case nil: model.selected = nil
                }
            })
            .contextMenu {
                if let n = model.hovered ?? model.selected { FileActions(node: n) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func centerLabel(_ g: RingGeometry) -> some View {
        let f = model.focus
        return VStack(spacing: 2) {
            if f?.parent != nil { Image(systemName: "arrow.up.circle").font(.system(size: 13)).foregroundStyle(.tertiary) }
            Text(f?.name ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
            Text(formatSize(f?.size ?? 0)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(width: g.r0 * 1.7)
        .position(g.center)
        .allowsHitTesting(false)
    }
}

struct HoverCaption: View {
    @EnvironmentObject var model: AnalyzerModel

    var body: some View {
        HStack(spacing: 8) {
            if let n = model.hovered {
                Circle().fill(model.color(n)).frame(width: 9, height: 9)
                Text(n.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(formatSize(n.size)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                if let f = model.focus, f.size > 0 {
                    Text(String(format: "%.1f%%", Double(n.size) / Double(f.size) * 100))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text("Clique num segmento para entrar na pasta · clique no centro para subir")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 18)
    }
}

// MARK: List

struct ChildrenList: View {
    @EnvironmentObject var model: AnalyzerModel

    var body: some View {
        let focus = model.focus
        let children = focus?.children ?? []
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Conteúdo", trailing: "\(children.count) itens")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            List(selection: Binding(get: { model.selected?.id }, set: { id in
                model.selected = children.first { $0.id == id }
            })) {
                ForEach(children) { n in
                    ChildRow(node: n, total: max(focus?.size ?? 1, 1), color: model.color(n), hovered: n === model.hovered)
                        .tag(n.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
                if let n = children.first(where: { ids.contains($0.id) }) { FileActions(node: n) }
            } primaryAction: { ids in
                if let n = children.first(where: { ids.contains($0.id) }) {
                    if n.isDir { model.setFocus(n) } else { NSWorkspace.shared.open(n.url) }
                }
            }
        }
    }
}

struct ChildRow: View {
    var node: FileNode
    var total: Int64
    var color: Color
    var hovered: Bool

    var body: some View {
        let f = Double(node.size) / Double(total)
        HStack(spacing: 9) {
            FileIcon(node: node, size: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.name).font(.system(size: 12, weight: hovered ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(formatSize(node.size)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                HStack(spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule().fill(color).frame(width: max(2, g.size.width * f))
                        }
                    }
                    .frame(height: 4)
                    Text(String(format: "%.1f%%", f * 100)).font(.system(size: 10)).foregroundStyle(.secondary)
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct FileIcon: View {
    var node: FileNode
    var size: CGFloat
    var body: some View {
        if node.isAggregate {
            Image(systemName: "doc.on.doc").font(.system(size: size * 0.6)).foregroundStyle(.secondary).frame(width: size, height: size)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path)).resizable().frame(width: size, height: size)
        }
    }
}

struct FileActions: View {
    @EnvironmentObject var model: AnalyzerModel
    var node: FileNode

    var body: some View {
        if node.isDir { Button("Analisar esta pasta") { model.setFocus(node) } }
        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        if !node.isAggregate {
            Button("Abrir") { NSWorkspace.shared.open(node.url) }
            Button("Copiar caminho") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
            Divider()
            Button("Mover para o Lixo", role: .destructive) { model.trash(node) }
                .disabled(node === model.root)
        }
    }
}

// MARK: Inspector

struct InspectorPane: View {
    @EnvironmentObject var model: AnalyzerModel
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let n = model.selected ?? model.focus { details(n) }
                if !model.largestFiles.isEmpty { largest }
            }
            .padding(14)
        }
    }

    private func details(_ n: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FileIcon(node: n, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(kind(n)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(formatSize(n.size)).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    if let p = n.parent, p.size > 0 {
                        share("da pasta \"\(p.name)\"", Double(n.size) / Double(p.size), model.color(n))
                    }
                    if model.volume.total > 0 {
                        share("do disco", Double(n.size) / Double(model.volume.total), Palette.cpu)
                    }
                    Divider()
                    row("Itens", n.items.formatted())
                    if n.isDir { row("Subpastas", n.children.filter(\.isDir).count.formatted()) }
                    if let d = n.modified { row("Modificado", d.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
            Text(n.url.path).font(.system(size: 10)).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(4)
            HStack(spacing: 6) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([n.url]) } label: { Label("Finder", systemImage: "folder") }
                if n.isDir && n !== model.focus {
                    Button { model.setFocus(n) } label: { Label("Analisar", systemImage: "chart.pie") }
                }
                if !n.isAggregate && n !== model.root {
                    Button(role: .destructive) { confirmTrash = true } label: { Label("Lixo", systemImage: "trash") }
                }
            }
            .controlSize(.small)
            .confirmationDialog("Mover \"\(n.name)\" (\(formatSize(n.size))) para o Lixo?", isPresented: $confirmTrash) {
                Button("Mover para o Lixo", role: .destructive) { model.trash(n) }
            }
        }
    }

    private var largest: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Maiores arquivos aqui")
            ForEach(model.largestFiles) { f in
                Button { model.selected = f } label: {
                    HStack(spacing: 7) {
                        FileIcon(node: f, size: 16)
                        Text(f.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(formatSize(f.size)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { FileActions(node: f) }
            }
        }
    }

    private func share(_ label: String, _ f: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", f * 100)).font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: max(2, g.size.width * min(f, 1)))
                }
            }
            .frame(height: 5)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private func kind(_ n: FileNode) -> String {
        if n.isAggregate { return "Arquivos agrupados" }
        if n.isDir { return (try? n.url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) ?? "Pasta" }
        return (try? n.url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) ?? "Arquivo"
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AnalyzerModel

    var body: some View {
        let v = model.volume
        HStack(spacing: 12) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            Text(v.name).font(.system(size: 11, weight: .medium))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(v.fraction > 0.9 ? Palette.hot : Palette.cpu).frame(width: g.size.width * v.fraction)
                }
            }
            .frame(width: 160, height: 6)
            Text("\(formatSize(v.available)) livres de \(formatSize(v.total))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if let r = model.root, !model.scanning {
                Text("\(r.items.formatted()) arquivos · \(formatSize(r.size)) · \(String(format: "%.1f s", model.scanDuration))\(model.partial ? " · parcial" : "")")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}
