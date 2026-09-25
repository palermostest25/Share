import AppKit

let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(origin: .zero, size: size).insetBy(dx: 56, dy: 56)
let path = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.84, blue: 0.79, alpha: 1), NSColor(calibratedRed: 0.34, green: 0.55, blue: 1, alpha: 1)])!
gradient.draw(in: path, angle: -45)
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 560, weight: .heavy),
    .foregroundColor: NSColor(calibratedWhite: 0.04, alpha: 1)
]
let string = NSAttributedString(string: "S", attributes: attributes)
let bounds = string.size()
string.draw(at: NSPoint(x: (1024-bounds.width)/2, y: (1024-bounds.height)/2 + 48))
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
