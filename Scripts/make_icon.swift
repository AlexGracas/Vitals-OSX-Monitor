import AppKit
let out = CommandLine.arguments[1]
let img = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { r in
    let path = NSBezierPath(roundedRect: r.insetBy(dx: 100, dy: 100), xRadius: 180, yRadius: 180)
    NSGradient(colors: [NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1), NSColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)])!.draw(in: path, angle: -45)
    let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        sym.draw(in: NSRect(x: (1024 - s.width) / 2, y: (1024 - s.height) / 2, width: s.width, height: s.height))
    }
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
