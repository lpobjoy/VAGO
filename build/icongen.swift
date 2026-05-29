import AppKit

// Renders the YTGrab app icon at a given pixel size into a PNG.
func drawIcon(size: CGFloat) -> Data {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Rounded-rect "squircle" mask (macOS Big Sur style corner ~22.37%).
    let corner = size * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    path.addClip()

    // Background gradient: deep magenta -> red -> orange (energetic, media-ish).
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.45, green: 0.10, blue: 0.55, alpha: 1), // purple
        NSColor(calibratedRed: 0.86, green: 0.13, blue: 0.27, alpha: 1), // red
        NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.18, alpha: 1), // orange
    ])!
    grad.draw(in: rect, angle: -55)

    // Soft top highlight for depth.
    let hi = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.22),
        NSColor(white: 1, alpha: 0.0),
    ])!
    hi.draw(in: CGRect(x: 0, y: size * 0.5, width: size, height: size * 0.5), angle: -90)

    // White rounded play triangle in the upper area.
    let c = size / 2
    let triR = size * 0.20
    let triCY = size * 0.60
    let tri = NSBezierPath()
    // Equilateral-ish triangle pointing right.
    let p1 = CGPoint(x: c - triR * 0.55, y: triCY + triR * 0.72)
    let p2 = CGPoint(x: c - triR * 0.55, y: triCY - triR * 0.72)
    let p3 = CGPoint(x: c + triR * 0.85, y: triCY)
    tri.move(to: p1); tri.line(to: p2); tri.line(to: p3); tri.close()
    tri.lineJoinStyle = .round
    tri.lineWidth = size * 0.045
    NSColor.white.setStroke()
    NSColor.white.setFill()
    tri.stroke()
    tri.fill()

    // Downward arrow below (the "download" cue), in white.
    let arrowW = size * 0.14
    let stemX = c
    let stemTop = size * 0.42
    let stemBot = size * 0.22
    let stem = NSBezierPath()
    stem.move(to: CGPoint(x: stemX, y: stemTop))
    stem.line(to: CGPoint(x: stemX, y: stemBot))
    stem.lineWidth = size * 0.05
    stem.lineCapStyle = .round
    NSColor.white.setStroke()
    stem.stroke()

    let head = NSBezierPath()
    head.move(to: CGPoint(x: stemX - arrowW / 2, y: stemBot + arrowW * 0.55))
    head.line(to: CGPoint(x: stemX, y: stemBot - arrowW * 0.15))
    head.line(to: CGPoint(x: stemX + arrowW / 2, y: stemBot + arrowW * 0.55))
    head.lineWidth = size * 0.05
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    img.unlockFocus()

    let tiff = img.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// iconutil-required sizes (1x and 2x).
let specs: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for s in specs {
    let data = drawIcon(size: s.px)
    let url = URL(fileURLWithPath: "\(outDir)/\(s.name).png")
    try! data.write(to: url)
}
print("icons written to \(outDir)")
