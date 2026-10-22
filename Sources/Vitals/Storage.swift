import Foundation
import AppKit

struct VolumeInfo {
    var name = ""
    var total: Int64 = 0
    var available: Int64 = 0          // what the system will hand out (includes purgeable space)
    var free: Int64 = 0               // strictly free blocks
    var used: Int64 { max(total - available, 0) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func read(_ url: URL = URL(fileURLWithPath: "/")) -> VolumeInfo {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return VolumeInfo() }
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeInfo(name: v.volumeLocalizedName ?? "Macintosh HD", total: Int64(v.volumeTotalCapacity ?? 0),
                          available: max(v.volumeAvailableCapacityForImportantUsage ?? 0, free), free: free)
    }
}

struct StorageDir: Identifiable {
    var id: String { url.path }
    var name: String
    var icon: String
    var url: URL
    var size: Int64?          // nil while being measured
    var unreadable = false
}

/// Disk usage of the volume and of the main folders, for the "Armazenamento" tab.
///
/// Power strategy: folder sizes require walking the whole tree, so they are only measured when the
/// tab is shown and the previous result is older than 10 minutes; the walk runs at utility QoS.
@MainActor
final class StorageModel: ObservableObject {
    @Published private(set) var volume = VolumeInfo()
    @Published private(set) var dirs: [StorageDir] = []
    @Published private(set) var measuring = false
    private var lastMeasure = Date.distantPast

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        var list: [StorageDir] = [
            StorageDir(name: "Aplicativos", icon: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")),
            StorageDir(name: "Mesa", icon: "menubar.dock.rectangle", url: home.appendingPathComponent("Desktop")),
            StorageDir(name: "Documentos", icon: "doc", url: home.appendingPathComponent("Documents")),
            StorageDir(name: "Downloads", icon: "arrow.down.circle", url: home.appendingPathComponent("Downloads")),
            StorageDir(name: "Imagens", icon: "photo", url: home.appendingPathComponent("Pictures")),
            StorageDir(name: "Filmes", icon: "film", url: home.appendingPathComponent("Movies")),
            StorageDir(name: "Música", icon: "music.note", url: home.appendingPathComponent("Music")),
            StorageDir(name: "Biblioteca", icon: "building.columns", url: home.appendingPathComponent("Library")),
        ]
        for (name, icon, path) in [("Developer", "hammer", "Developer"), ("Projetos", "folder", "Projects")]
        where fm.fileExists(atPath: home.appendingPathComponent(path).path) {
            list.append(StorageDir(name: name, icon: icon, url: home.appendingPathComponent(path)))
        }
        list.append(StorageDir(name: "Lixeira", icon: "trash", url: home.appendingPathComponent(".Trash")))
        dirs = list
        volume = VolumeInfo.read()
    }

    func refreshIfStale() {
        volume = VolumeInfo.read()
        if !measuring && Date().timeIntervalSince(lastMeasure) > 10 * 60 { measure() }
    }

    func measure() {
        guard !measuring else { return }
        measuring = true
        lastMeasure = Date()
        let urls = dirs.map(\.url)
        DispatchQueue.global(qos: .utility).async {
            var sizes = [Int64?](repeating: nil, count: urls.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                let s = DiskScanner.quickSize(urls[i])
                lock.lock(); sizes[i] = s; lock.unlock()
            }
            DispatchQueue.main.async {
                for i in self.dirs.indices {
                    self.dirs[i].size = sizes[i] ?? 0
                    self.dirs[i].unreadable = sizes[i] == nil
                }
                self.measuring = false
            }
        }
    }

    /// Largest measured folder, used to scale the bars.
    var maxSize: Int64 { dirs.compactMap(\.size).max() ?? 0 }
}

// MARK: - Tree scanner (detailed analysis)

final class FileNode: Identifiable {
    let name: String
    let url: URL
    let isDir: Bool
    let isAggregate: Bool      // stands for many small files folded together
    var size: Int64
    var items: Int             // files below (inclusive)
    var modified: Date?
    var children: [FileNode] = []
    weak var parent: FileNode?

    init(name: String, url: URL, isDir: Bool, size: Int64 = 0, items: Int = 0, modified: Date? = nil, isAggregate: Bool = false) {
        self.name = name; self.url = url; self.isDir = isDir; self.size = size
        self.items = items; self.modified = modified; self.isAggregate = isAggregate
    }

    var path: [FileNode] {
        var p: [FileNode] = [], n: FileNode? = self
        while let c = n { p.insert(c, at: 0); n = c.parent }
        return p
    }

    func contains(_ other: FileNode) -> Bool {
        var n: FileNode? = other
        while let c = n { if c === self { return true }; n = c.parent }
        return false
    }
}

/// Shared progress counters, written by scan threads and polled by the UI.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _files = 0, _bytes: Int64 = 0, _current = ""
    private var _cancelled = false

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    func add(files: Int, bytes: Int64, current: String) {
        lock.lock(); _files += files; _bytes += bytes; _current = current; lock.unlock()
    }
    var snapshot: (files: Int, bytes: Int64, current: String) {
        lock.lock(); defer { lock.unlock() }; return (_files, _bytes, _current)
    }
}

enum DiskScanner {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                                 .fileAllocatedSizeKey, .contentModificationDateKey, .volumeIdentifierKey]
    /// Files kept as individual nodes per folder; the rest are folded into one "smaller files" node,
    /// which keeps memory bounded when scanning folders with hundreds of thousands of files.
    private static let filesPerDir = 40

    /// Total allocated size of a folder, without building a tree. nil when the folder can't be read.
    static func quickSize(_ url: URL) -> Int64? {
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                                                     options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        for case let u as URL in e {
            if let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Builds the tree under `root`. Top-level subfolders are walked in parallel; mount points of
    /// other volumes are not crossed.
    static func scan(_ root: URL, progress: ScanProgress) -> FileNode {
        let fm = FileManager.default
        let rootValues = try? root.resourceValues(forKeys: [.volumeIdentifierKey, .contentModificationDateKey])
        let volume = rootValues?.volumeIdentifier as? NSObject
        let name = root.path == "/" ? "/" : (fm.displayName(atPath: root.path))
        let node = FileNode(name: name, url: root, isDir: true, modified: rootValues?.contentModificationDate)

        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])) ?? []
        var subdirs: [(URL, URLResourceValues)] = []
        var files: [FileNode] = []
        for u in entries {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true && v.isSymbolicLink != true { subdirs.append((u, v)) }
            else { files.append(fileNode(u, v)) }
        }
        var results = [FileNode?](repeating: nil, count: subdirs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
            let (u, v) = subdirs[i]
            if let volume, let vid = v.volumeIdentifier as? NSObject, !vid.isEqual(volume) { return }
            let n = walk(u, v, volume: volume, progress: progress)
            lock.lock(); results[i] = n; lock.unlock()
        }
        progress.add(files: files.count, bytes: files.reduce(0) { $0 + $1.size }, current: root.path)
        finish(node, dirs: results.compactMap { $0 }, files: files)
        return node
    }

    private static func walk(_ url: URL, _ values: URLResourceValues, volume: NSObject?, progress: ScanProgress) -> FileNode {
        let node = FileNode(name: url.lastPathComponent, url: url, isDir: true, modified: values.contentModificationDate)
        guard !progress.cancelled else { return node }
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        var dirs: [FileNode] = [], files: [FileNode] = []
        var bytes: Int64 = 0
        for u in entries {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true && v.isSymbolicLink != true {
                if let volume, let vid = v.volumeIdentifier as? NSObject, !vid.isEqual(volume) { continue }
                dirs.append(walk(u, v, volume: volume, progress: progress))
            } else {
                let f = fileNode(u, v)
                bytes += f.size
                files.append(f)
            }
        }
        progress.add(files: files.count, bytes: bytes, current: url.path)
        finish(node, dirs: dirs, files: files)
        return node
    }

    private static func fileNode(_ u: URL, _ v: URLResourceValues) -> FileNode {
        FileNode(name: u.lastPathComponent, url: u, isDir: false,
                 size: Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0), items: 1, modified: v.contentModificationDate)
    }

    private static func finish(_ node: FileNode, dirs: [FileNode], files: [FileNode]) {
        var kept = files.sorted { $0.size > $1.size }
        if kept.count > filesPerDir {
            let rest = kept[filesPerDir...]
            let agg = FileNode(name: "\(rest.count) arquivos menores", url: node.url, isDir: false,
                               size: rest.reduce(0) { $0 + $1.size }, items: rest.count, isAggregate: true)
            kept = Array(kept.prefix(filesPerDir)) + [agg]
        }
        node.children = (dirs + kept).sorted { $0.size > $1.size }
        node.size = node.children.reduce(0) { $0 + $1.size }
        node.items = node.children.reduce(0) { $0 + $1.items }
        for c in node.children { c.parent = node }
    }
}

func formatSize(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
