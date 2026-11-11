import AppKit

// Export the same symbol used in the window header, as requested.
let output = CommandLine.arguments[1]
let edge = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: edge, height: edge).fill(using: .copy)
let symbol = NSImage(
    systemSymbolName: "externaldrive.badge.icloud", accessibilityDescription: nil
)!.withSymbolConfiguration(.init(pointSize: 640, weight: .regular))!
let scale = min(844 / symbol.size.width, 844 / symbol.size.height)
let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
symbol.draw(in: NSRect(x: (CGFloat(edge) - size.width) / 2,
                       y: (CGFloat(edge) - size.height) / 2,
                       width: size.width, height: size.height))
NSColor(srgbRed: 1, green: 0.27, blue: 0.29, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: edge, height: edge).fill(using: .sourceIn)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: output), options: .atomic
)
