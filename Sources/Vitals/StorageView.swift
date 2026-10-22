import SwiftUI

struct StorageView: View {
    @EnvironmentObject var storage: StorageModel

    var body: some View {
        VStack(spacing: 12) {
            volumeCard
            dirsCard
            Button { AnalyzerWindow.shared.open(FileManager.default.homeDirectoryForCurrentUser) } label: {
                Label("Análise detalhada…", systemImage: "chart.pie.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.cpu))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .onAppear { storage.refreshIfStale() }
    }

    private var volumeCard: some View {
        let v = storage.volume
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: v.name, trailing: "\(formatSize(v.total))")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatSize(v.available)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("livres").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((v.fraction * 100).rounded()))% usado").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(LinearGradient(colors: [Palette.cpu, v.fraction > 0.9 ? Palette.hot : Palette.memory],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * v.fraction)
                    }
                }
                .frame(height: 8)
                if v.available - v.free > 1_000_000_000 {
                    Text("Inclui \(formatSize(v.available - v.free)) purgáveis (caches e cópias locais que o sistema libera quando precisa).")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var dirsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Pastas principais")
                    if storage.measuring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button { storage.measure() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Medir novamente")
                    }
                }
                ForEach(storage.dirs) { DirRow(dir: $0, maxSize: storage.maxSize) }
            }
        }
    }
}

struct DirRow: View {
    var dir: StorageDir
    var maxSize: Int64
    @State private var hover = false

    var body: some View {
        Button { AnalyzerWindow.shared.open(dir.url) } label: {
            HStack(spacing: 8) {
                Image(systemName: dir.icon).font(.system(size: 11)).foregroundStyle(Palette.cpu).frame(width: 16)
                Text(dir.name).font(.system(size: 12))
                Spacer()
                if dir.unreadable {
                    Text("sem acesso").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if let s = dir.size {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(Palette.cpu.opacity(0.85))
                                .frame(width: max(2, g.size.width * (maxSize > 0 ? Double(s) / Double(maxSize) : 0)))
                        }
                    }
                    .frame(width: 70, height: 5)
                    Text(formatSize(s)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 62, alignment: .trailing)
                } else {
                    Text("…").foregroundStyle(.tertiary).frame(width: 62, alignment: .trailing)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
            }
            .padding(.vertical, 2).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Análise detalhada de \(dir.url.path)")
    }
}
