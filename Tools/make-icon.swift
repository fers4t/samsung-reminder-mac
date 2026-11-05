// Renders the app icon: a blue→indigo squircle with a white check ring and a bell dot.
// Usage: swift Tools/make-icon.swift <output.png>
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: artwork inset ~10%, corner radius ~22.4% of the artwork size.
let inset = size * 0.10
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.224, yRadius: rect.width * 0.224)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1).setFill()
squircle.fill()
ctx.restoreGState()

squircle.addClip()
let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.33, green: 0.62, blue: 1.0, alpha: 1),
                                   NSColor(calibratedRed: 0.22, green: 0.30, blue: 0.85, alpha: 1)])!
gradient.draw(in: rect, angle: -70)

// Soft highlight on the top edge.
let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.18)])!
highlight.draw(in: rect, angle: 90)

// Check ring.
let center = CGPoint(x: size / 2, y: size / 2 - size * 0.01)
let ringRadius = size * 0.26
let ring = NSBezierPath(ovalIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
ring.lineWidth = size * 0.052
NSColor.white.setStroke()
ring.stroke()

let check = NSBezierPath()
check.lineWidth = size * 0.062
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.move(to: CGPoint(x: center.x - ringRadius * 0.46, y: center.y + ringRadius * 0.02))
check.line(to: CGPoint(x: center.x - ringRadius * 0.10, y: center.y - ringRadius * 0.34))
check.line(to: CGPoint(x: center.x + ringRadius * 0.52, y: center.y + ringRadius * 0.36))
check.stroke()

// Notification dot at the ring's top-right.
let dotRadius = size * 0.062
let dotCenter = CGPoint(x: center.x + ringRadius * 0.80, y: center.y + ringRadius * 0.80)
NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.30, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)).fill()
NSColor.white.setStroke()
let dotRing = NSBezierPath(ovalIn: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
dotRing.lineWidth = size * 0.022
dotRing.stroke()

image.unlockFocus()
let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
