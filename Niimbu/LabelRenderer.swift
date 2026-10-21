import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import NiimbotKit
import SwiftUI

/// Pixel geometry of the printable canvas for a label on a given printer.
struct CanvasGeometry: Equatable {
    var dotsPerMm: Double
    var width: Int
    var height: Int
    /// The label is taller (across the printhead) than the printer can print.
    var isClipped: Bool

    init(size: LabelSize, model: PrinterModel) {
        dotsPerMm = model.dotsPerMm
        let w = Int((size.width * dotsPerMm).rounded())
        let h = Int((size.height * dotsPerMm).rounded())
        // The printhead runs across the label height on D-series (direction .left), across the width on B-series.
        switch model.direction {
        case .left:
            width = w
            height = min(h, model.printheadPixels)
            isClipped = h > model.printheadPixels
        case .top:
            width = min(w, model.printheadPixels)
            height = h
            isClipped = w > model.printheadPixels
        }
    }

    func px(_ mm: Double) -> CGFloat { CGFloat(mm * dotsPerMm) }
}

@MainActor
enum LabelRenderer {
    private static let supersample = 4

    /// Renders the label to the 1-bit image that is sent to the printer.
    /// `copy` picks the value of any `{#}` counter: 0 for the first label of a print run, 1 for the next…
    static func render(_ elements: [LabelElement], geometry: CanvasGeometry, cableFlag: Bool = false, copy: Int = 0) -> MonoBitmap {
        let all = cableFlag ? elements + flagMirrored(elements, geometry: geometry) : elements
        let view = LabelContentView(elements: all, geometry: geometry, copy: copy)
        let renderer = ImageRenderer(content: view)
        // Render at 4× and average down to printer dots: edges land on the dots they mostly cover,
        // which gives cleaner letter shapes than anti-aliasing straight at 203 dpi.
        renderer.scale = CGFloat(supersample)
        renderer.proposedSize = ProposedViewSize(width: CGFloat(geometry.width), height: CGFloat(geometry.height))
        let w = geometry.width, h = geometry.height, n = supersample
        guard let cg = renderer.cgImage else { return MonoBitmap(width: w, height: h) }

        let big = grayscale(cg, width: w * n, height: h * n)
        var pixels = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0
                for sy in 0..<n {
                    let row = (y * n + sy) * w * n + x * n
                    for sx in 0..<n { sum += Int(big[row + sx]) }
                }
                // Black when at least half the dot is covered.
                pixels[y * w + x] = sum < 128 * n * n
            }
        }
        return MonoBitmap(width: w, height: h, pixels: pixels)
    }

    /// Cable flags fold in the middle, so everything in the left half is repeated upside down in the right
    /// half; both copies then read the right way up around the cable. Elements that reach into the right half
    /// (frames, fold lines, hand-made right halves) are left alone.
    static func flagMirrored(_ elements: [LabelElement], geometry: CanvasGeometry) -> [LabelElement] {
        let width = Double(geometry.width) / geometry.dotsPerMm, height = Double(geometry.height) / geometry.dotsPerMm
        return elements.filter { isLeftHalf($0, labelWidth: width) && !hasLinkedCopy($0, in: elements) }.map { e in
            var copy = e
            copy.id = UUID()
            copy.x = width - e.x - e.width
            copy.y = height - e.y - e.height
            copy.angle = (e.angle + 180) % 360
            return copy
        }
    }

    /// Close enough to the left half to be repeated: a little overlap past the fold is allowed.
    static func isLeftHalf(_ element: LabelElement, labelWidth: Double) -> Bool {
        element.x + element.width <= labelWidth / 2 + 2
    }

    /// Cable flags made by earlier versions have a linked right-half copy of their text; those aren't mirrored
    /// again. An element whose partner was deleted is.
    static func hasLinkedCopy(_ element: LabelElement, in elements: [LabelElement]) -> Bool {
        guard let link = element.linkID else { return false }
        return elements.contains { $0.linkID == link && $0.id != element.id }
    }

    /// Draws `image` onto white, scaled to `width`×`height`, and returns 8-bit luminance, top row first.
    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 255, count: width * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    static func cgImage(_ bitmap: MonoBitmap) -> CGImage? {
        let bytes = bitmap.pixels.map { $0 ? UInt8(0) : UInt8(255) }
        return cgImage(gray: bytes, width: bitmap.width, height: bitmap.height)
    }

    static func cgImage(gray: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Element images

    private static let ciContext = CIContext()

    /// A QR code scaled by a whole number of pixels per module so modules stay crisp.
    static func qrCode(_ text: String, fitting side: Int) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(CGFloat(side) / output.extent.width))
        return ciContext.createCGImage(output.transformed(by: .init(scaleX: scale, y: scale)), from: output.extent.applying(.init(scaleX: scale, y: scale)))
    }

    /// A Code 128 barcode with whole-pixel bar widths, stretched to `height`.
    static func barcode(_ text: String, width: Int, height: Int) -> CGImage? {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(text.utf8)
        filter.quietSpace = 0
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let sx = max(1, floor(CGFloat(width) / output.extent.width))
        let sy = CGFloat(height) / output.extent.height
        let t = CGAffineTransform(scaleX: sx, y: sy)
        return ciContext.createCGImage(output.transformed(by: t), from: output.extent.applying(t).integral)
    }

    /// Scales a photo/logo to fit, then converts to black and white.
    static func monochrome(_ data: Data, fitting box: CGSize, element e: LabelElement) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, box.width >= 1, box.height >= 1 else { return nil }
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))

        var gray = grayscale(image, width: w, height: h).map(Double.init)
        if e.invert { gray = gray.map { 255 - $0 } }
        let cut = e.threshold * 255
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let old = gray[i]
                let new: Double = old < cut ? 0 : 255
                out[i] = UInt8(new)
                guard e.dither else { continue }
                let err = old - new
                if x + 1 < w { gray[i + 1] += err * 7 / 16 }
                if y + 1 < h {
                    if x > 0 { gray[i + w - 1] += err * 3 / 16 }
                    gray[i + w] += err * 5 / 16
                    if x + 1 < w { gray[i + w + 1] += err * 1 / 16 }
                }
            }
        }
        return cgImage(gray: out, width: w, height: h)
    }
}

/// The label drawn in printer pixels (1 point = 1 dot). Used both for printing and on-screen editing.
struct LabelContentView: View {
    let elements: [LabelElement]
    let geometry: CanvasGeometry
    var copy = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(elements) { e in
                ElementContent(element: e, geometry: geometry, copy: copy)
                    .frame(width: geometry.px(e.width), height: geometry.px(e.height))
                    .offset(x: geometry.px(e.x), y: geometry.px(e.y))
            }
        }
        .frame(width: CGFloat(geometry.width), height: CGFloat(geometry.height), alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

private struct ElementContent: View {
    let element: LabelElement
    let geometry: CanvasGeometry
    let copy: Int

    var body: some View {
        let w = geometry.px(element.width), h = geometry.px(element.height)
        // Quarter turns lay the content out in the swapped box, then rotate it into place.
        let sideways = element.angle % 180 != 0
        content(width: sideways ? h : w, height: sideways ? w : h)
            .rotationEffect(.degrees(Double(element.angle)))
            .frame(width: w, height: h)
    }

    @ViewBuilder
    private func content(width w: CGFloat, height h: CGFloat) -> some View {
        switch element.kind {
        case .text:
            let size = element.fitToBox ? max(h, 6) : element.fontSize * geometry.dotsPerMm * 25.4 / 72
            Text(element.resolvedText(copy: copy))
                .font(font(size: size))
                .italic(element.isItalic)
                .fontWidth(element.fontDesign == .condensed ? .condensed : .standard)
                .minimumScaleFactor(element.fitToBox ? 0.01 : 1)
                .multilineTextAlignment(textAlignment)
                .foregroundStyle(.black)
                .frame(width: w, height: h, alignment: frameAlignment)
        case .qrCode:
            pixelImage(LabelRenderer.qrCode(element.resolvedText(copy: copy), fitting: Int(min(w, h))))
        case .barcode:
            pixelImage(LabelRenderer.barcode(element.resolvedText(copy: copy), width: Int(w), height: Int(h)))
        case .image:
            pixelImage(element.imageData.flatMap { LabelRenderer.monochrome($0, fitting: CGSize(width: w, height: h), element: element) })
        case .box:
            RoundedRectangle(cornerRadius: geometry.px(element.radius))
                .strokeBorder(.black, style: stroke)
                .frame(width: w, height: h)
        case .line:
            Path { p in
                if w >= h {
                    p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                } else {
                    p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                }
            }
            .stroke(.black, style: stroke)
            .frame(width: w, height: h)
        }
    }

    /// Dashes of 1 mm with 0.75 mm gaps.
    private var stroke: StrokeStyle {
        StrokeStyle(lineWidth: element.strokeDots, dash: element.isDashed ? [geometry.px(1), geometry.px(0.75)] : [])
    }

    @ViewBuilder
    private func pixelImage(_ image: CGImage?) -> some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.none)
        } else {
            Color.clear
        }
    }

    private var fontWeight: Font.Weight {
        switch element.textWeight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    private func font(size: CGFloat) -> Font {
        if let family = element.fontFamily {
            return .custom(family, fixedSize: size).weight(fontWeight)
        }
        return .system(size: size, weight: fontWeight, design: fontDesign)
    }

    private var fontDesign: Font.Design {
        switch element.fontDesign {
        case .standard, .condensed: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }

    private var textAlignment: TextAlignment {
        switch element.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch element.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
