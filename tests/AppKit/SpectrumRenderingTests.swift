import AppKit

func spectrumRenderingTests() throws {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            fputs("FAIL: \(message)\n", stderr)
        }
    }
    let audit = ProcessInfo.processInfo.environment["CLIAMPBAR_SPECTRUM_AUDIT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    if let audit { try FileManager.default.createDirectory(at: audit, withIntermediateDirectories: true) }

    for scale in [1, 2] {
        let view = SpectrumView(frame: NSRect(x: 0, y: 0, width: 348, height: 32))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 348 * scale, pixelsHigh: 32 * scale,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        func render(_ bands: [Double], name: String) throws {
            view.bands = bands
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.displayIgnoringOpacity(view.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
            if let audit {
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: audit.appendingPathComponent("\(name)-\(scale)x.png"))
            }
        }
        func isBright(_ x: Int, _ y: Int) -> Bool {
            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            return color.redComponent > 0.7 && color.greenComponent > 0.7 && color.blueComponent > 0.6
        }
        func brightRows(column: Int) -> [Int] {
            let x = Int((CGFloat(column) * 35.3 + 15) * CGFloat(scale))
            return (0..<bitmap.pixelsHigh).filter { isBright(x, $0) }
        }
        func brightPixelCount() -> Int {
            (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).filter { isBright($0, y) }.count
            }
        }

        try render(Array(repeating: 0, count: 10), name: "silence")
        check(brightPixelCount() == 0, "\(scale)x silence has no bright pixels")
        let baseline = bitmap.colorAt(x: 15 * scale, y: bitmap.pixelsHigh - 1)!.usingColorSpace(.sRGB)!
        let surface = bitmap.colorAt(x: 15 * scale, y: 0)!.usingColorSpace(.sRGB)!
        check(baseline.redComponent > surface.redComponent && baseline.redComponent < 0.4,
              "\(scale)x silence retains a dim baseline at the bottom")

        try render([Double.leastNonzeroMagnitude, 1e-323, 1e-100, 1e-8, 0.001, 0.007, 0, 0, 0, 0], name: "tails")
        let tailPixels = brightPixelCount()
        check(tailPixels == 0, "\(scale)x tiny tails have \(tailPixels) bright pixels, expected 0")

        try render([0, 0.03125, 0.0625, 0.125, 0.2, 0.24, 0.5, 0.625, 0.75, 1], name: "levels")
        let expectedHeights = scale == 1 ? [0, 1, 2, 4, 6, 7, 16, 20, 24, 32] : [0, 2, 4, 8, 12, 15, 32, 40, 48, 64]
        let heights = (0..<10).map { brightRows(column: $0).count }
        check(heights == expectedHeights, "\(scale)x proportional heights are \(heights), expected \(expectedHeights)")
        check(heights[4] < heights[5], "\(scale)x levels 0.20 and 0.24 retain different heights inside one old bucket")
        for column in 0..<10 {
            let rows = brightRows(column: column)
            let expectedRows = Array((bitmap.pixelsHigh - expectedHeights[column])..<bitmap.pixelsHigh)
            check(rows == expectedRows, "\(scale)x column \(column) is solid and grows upward from the bottom")
        }
        for gap in 0..<9 {
            let x = Int((CGFloat(gap) * 35.3 + 33) * CGFloat(scale))
            check((0..<bitmap.pixelsHigh).allSatisfy { !isBright(x, $0) },
                  "\(scale)x gap \(gap) separates frequency columns")
        }
        check((0..<bitmap.pixelsWide).filter { isBright($0, 0) }.allSatisfy { $0 >= 317 * scale },
              "\(scale)x only the full-height column reaches the top")

        try render([], name: "cleared")
        let clearedPixels = brightPixelCount()
        check(clearedPixels == 0, "\(scale)x clear removes all old bright pixels, found \(clearedPixels)")
        print("Spectrum bitmap \(scale)x: tailPixels=\(tailPixels), heights=\(heights), clearedPixels=\(clearedPixels)")
    }
    expect(failures == 0, "Spectrum bitmap rendering has \(failures) failures")
    print("PASS: actual AppKit spectrum bitmaps at 1x and 2x, silence, tiny tails, proportional heights, direction, gaps, full height, clear")
}
