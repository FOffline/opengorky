// Renders the game launcher's icons (assets/launcher/icons/*.svg, monochrome, currentColor)
// into white 48×48 PNGs beside them, tinted when drawn. macOS (AppKit draws the SVGs):
//   swift scripts/launcher-icons.swift assets/launcher/icons
import AppKit

let dir = CommandLine.arguments[1]
let size = 48
for file in try! FileManager.default.contentsOfDirectory(atPath: dir) where file.hasSuffix(".svg") {
    let s = try! String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)
        .replacingOccurrences(of: "currentColor", with: "#ffffff")
    let img = NSImage(data: s.data(using: .utf8)!)!
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let png = "\(dir)/\(file.dropLast(4)).png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
}
