import Combine
import CoreGraphics
import SwiftUI

/// A small waterfall at the top of the window: each new magnitude spectrum
/// of the received audio (over a fixed frequency band) becomes a new row,
/// with older rows scrolling down over time. Ported from
/// JttyChatLinux/src/SpectrumWidget.{h,cpp} (which used QImage/QPainter);
/// this builds the same kind of raw RGBA bitmap and renders it as a
/// CGImage.
final class WaterfallBitmap: ObservableObject {
    static let height = 90 // waterfall rows kept ~= seconds of history at the update rate

    // Display range; actual signal + noise floor levels vary a lot by sound
    // card and mic gain, so these are just reasonable defaults for
    // "something is there" visibility rather than a calibrated reading.
    private static let minDb: Float = -90.0
    private static let maxDb: Float = -20.0

    private struct ColorStop {
        let position: Float
        let r, g, b: UInt8
    }

    // Dark blue (quiet) -> blue -> teal -> yellow -> red (loud), a simple
    // hand-rolled stand-in for a classic SDR waterfall colormap.
    private static let colorStops: [ColorStop] = [
        ColorStop(position: 0.00, r: 8, g: 10, b: 30),
        ColorStop(position: 0.35, r: 20, g: 40, b: 170),
        ColorStop(position: 0.55, r: 30, g: 180, b: 170),
        ColorStop(position: 0.75, r: 230, g: 210, b: 40),
        ColorStop(position: 1.00, r: 235, g: 40, b: 30),
    ]

    private static func color(forMagnitudeDb db: Float) -> (UInt8, UInt8, UInt8) {
        let t = min(max((db - minDb) / (maxDb - minDb), 0.0), 1.0)
        var i = 0
        while i < colorStops.count - 2 && t > colorStops[i + 1].position { i += 1 }
        let a = colorStops[i]
        let b = colorStops[i + 1]
        let span = b.position - a.position
        let localT = span > 0 ? (t - a.position) / span : 0
        let r = UInt8(Float(a.r) + Float(Int(b.r) - Int(a.r)) * localT)
        let g = UInt8(Float(a.g) + Float(Int(b.g) - Int(a.g)) * localT)
        let blue = UInt8(Float(a.b) + Float(Int(b.b) - Int(a.b)) * localT)
        return (r, g, blue)
    }

    @Published private(set) var image: CGImage?
    private var width = 0
    private var pixels: [UInt8] = [] // RGBA8, row-major, newest row first

    func setMagnitudesDb(_ magnitudesDb: [Float]) {
        let n = magnitudesDb.count
        guard n >= 1 else { return }

        if width != n {
            width = n
            let (r, g, b) = Self.color(forMagnitudeDb: Self.minDb)
            pixels = [UInt8](repeating: 0, count: n * Self.height * 4)
            for row in 0..<Self.height {
                for col in 0..<n {
                    let offset = (row * n + col) * 4
                    pixels[offset] = r
                    pixels[offset + 1] = g
                    pixels[offset + 2] = b
                    pixels[offset + 3] = 255
                }
            }
        }

        // Shift every row down by one, then paint the newest spectrum into
        // the now-free top row.
        let rowBytes = width * 4
        pixels.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            memmove(base + rowBytes, base, rowBytes * (Self.height - 1))
        }
        for col in 0..<width {
            let (r, g, b) = Self.color(forMagnitudeDb: magnitudesDb[col])
            let offset = col * 4
            pixels[offset] = r
            pixels[offset + 1] = g
            pixels[offset + 2] = b
            pixels[offset + 3] = 255
        }

        image = makeImage()
    }

    private func makeImage() -> CGImage? {
        guard width > 0 else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true,
                        intent: .defaultIntent)
    }
}

struct SpectrumView: View {
    @ObservedObject var bitmap: WaterfallBitmap
    let lowHz: Int
    let highHz: Int

    // Marker at the default JTTY tone, so it's obvious where to look.
    private let defaultToneHz = Int(Jtty.defaultToneHz)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 8.0 / 255, green: 10.0 / 255, blue: 30.0 / 255)
                if let image = bitmap.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                }
                if lowHz <= defaultToneHz && defaultToneHz <= highHz {
                    let x = geometry.size.width * CGFloat(defaultToneHz - lowHz) / CGFloat(highHz - lowHz)
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                    .stroke(Color.white.opacity(0.27), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
        .frame(height: CGFloat(WaterfallBitmap.height))
        .clipped()
    }
}
