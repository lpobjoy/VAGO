import AppKit

// Draws the DMG background. We render at 2x (1200x800) and tag it so the
// Finder treats it as a 600x400 Retina background.
let W: CGFloat = 1200, H: CGFloat = 800
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

let rect = CGRect(x: 0, y: 0, width: W, height: H)

// Soft light background gradient.
NSGradient(colors: [
    NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.99, alpha: 1),
    NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.96, alpha: 1),
])!.draw(in: rect, angle: -90)

// Brand gradient accent bar across the top.
NSGradient(colors: [
    NSColor(calibratedRed: 0.45, green: 0.10, blue: 0.55, alpha: 1),
    NSColor(calibratedRed: 0.86, green: 0.13, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.18, alpha: 1),
])!.draw(in: CGRect(x: 0, y: H - 150, width: W, height: 150), angle: 0)

// Title text on the accent bar.
let title = "YTGrab"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 64, weight: .heavy),
    .foregroundColor: NSColor.white,
]
title.draw(at: CGPoint(x: 70, y: H - 120), withAttributes: titleAttrs)

let sub = "Drag the app onto the Applications folder to install"
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 30, weight: .medium),
    .foregroundColor: NSColor(white: 0.25, alpha: 1),
]
let subSize = (sub as NSString).size(withAttributes: subAttrs)
sub.draw(at: CGPoint(x: (W - subSize.width) / 2, y: 90), withAttributes: subAttrs)

// Big arrow from app (left) to Applications (right), centered vertically.
let arrowY: CGFloat = 420
let arrow = NSBezierPath()
arrow.move(to: CGPoint(x: 470, y: arrowY))
arrow.line(to: CGPoint(x: 730, y: arrowY))
arrow.lineWidth = 14
arrow.lineCapStyle = .round
NSColor(calibratedRed: 0.86, green: 0.13, blue: 0.27, alpha: 0.85).setStroke()
arrow.stroke()
// Arrow head
let head = NSBezierPath()
head.move(to: CGPoint(x: 700, y: arrowY + 32))
head.line(to: CGPoint(x: 745, y: arrowY))
head.line(to: CGPoint(x: 700, y: arrowY - 32))
head.lineWidth = 14
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmgbg.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
