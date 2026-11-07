// Renders assets/icon.png: a pull-request glyph on a dark macOS-style tile.
// Regenerate with script/make-icon.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Apple's icon grid: an 824pt tile centred on a 1024pt canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1),
    ending: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.11, alpha: 1)
)!.draw(in: tilePath, angle: -90)

let green = NSColor(srgbRed: 0.25, green: 0.73, blue: 0.31, alpha: 1)
let blue = NSColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 1)
let stroke = 44.0
let radius = 62.0

func ring(_ x: Double, _ y: Double, _ color: NSColor) {
    let path = NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    path.lineWidth = stroke
    color.setStroke()
    path.stroke()
}

func line(_ build: (NSBezierPath) -> Void, _ color: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = stroke
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    build(path)
    color.setStroke()
    path.stroke()
}

let left = 370.0, right = 654.0, top = 712.0, bottom = 312.0

// Base branch: a straight trunk between two commits.
line({ $0.move(to: NSPoint(x: left, y: top - radius)); $0.line(to: NSPoint(x: left, y: bottom + radius)) }, green)
ring(left, top, green)
ring(left, bottom, green)

// Head branch: a commit that curves back toward the base, with an arrowhead.
line({
    $0.move(to: NSPoint(x: right, y: bottom + radius))
    $0.line(to: NSPoint(x: right, y: 560))
    $0.curve(to: NSPoint(x: 540, y: top), controlPoint1: NSPoint(x: right, y: 660), controlPoint2: NSPoint(x: 600, y: top))
    $0.line(to: NSPoint(x: 492, y: top))
}, blue)
line({
    $0.move(to: NSPoint(x: 556, y: top + 64))
    $0.line(to: NSPoint(x: 492, y: top))
    $0.line(to: NSPoint(x: 556, y: top - 64))
}, blue)
ring(right, bottom, blue)

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
