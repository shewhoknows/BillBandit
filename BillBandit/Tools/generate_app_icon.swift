import AppKit

guard CommandLine.arguments.count == 7 else {
    fputs("usage: generate_app_icon source.pdf output.png cropX cropY cropWidth cropHeight\n", stderr)
    exit(2)
}

let sourcePath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let values = CommandLine.arguments[3...].compactMap(Double.init)

guard values.count == 4, let mascot = NSImage(contentsOfFile: sourcePath) else {
    fputs("could not load the mascot or crop values\n", stderr)
    exit(2)
}

let canvasSize = NSSize(width: 1024, height: 1024)
guard
    let bitmapContext = CGContext(
        data: nil,
        width: Int(canvasSize.width),
        height: Int(canvasSize.height),
        bitsPerComponent: 8,
        bytesPerRow: Int(canvasSize.width) * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
else {
    fputs("could not create the app icon canvas\n", stderr)
    exit(1)
}

// The icon background must match the app's full-bleed #1F3FC3 cobalt exactly.
bitmapContext.setFillColor(
    red: 0x1F / 255.0,
    green: 0x3F / 255.0,
    blue: 0xC3 / 255.0,
    alpha: 1
)
bitmapContext.fill(CGRect(origin: .zero, size: canvasSize))

let context = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let crop = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
mascot.draw(
    in: NSRect(origin: .zero, size: canvasSize),
    from: crop,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
)

bitmapContext.flush()
NSGraphicsContext.restoreGraphicsState()

guard
    let rendered = bitmapContext.makeImage(),
    let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
else {
    fputs("could not encode the app icon\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    fputs("could not write the app icon: \(error)\n", stderr)
    exit(1)
}
