import Foundation

public enum PrintDirection: Sendable {
    /// Printhead runs along the image width (B-series).
    case top
    /// Image is rotated 90° clockwise before printing; printhead runs along the image height (D-series).
    case left
}

/// A 1-bit image. `true` is a black (printed) pixel.
public struct MonoBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Bool]

    public init(width: Int, height: Int, pixels: [Bool]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? Array(repeating: false, count: width * height)
        precondition(self.pixels.count == width * height)
    }

    public subscript(x: Int, y: Int) -> Bool {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

public struct EncodedImage: Equatable, Sendable {
    public enum Row: Equatable, Sendable {
        case void(rowNumber: Int, repeat: Int)
        case pixels(rowNumber: Int, repeat: Int, data: [UInt8], blackCount: Int)
        /// Sent every 200 rows when check lines are enabled.
        case check(rowNumber: Int)
    }

    /// Printhead-axis size in pixels (padded to a multiple of 8).
    public let cols: Int
    /// Feed-axis size in pixels.
    public let rows: Int
    public let rowsData: [Row]
}

/// Converts a bitmap into printer rows, merging identical consecutive rows. Ported from niimbluelib.
public enum ImageEncoder {
    public static func encode(_ bitmap: MonoBitmap, direction: PrintDirection) -> EncodedImage {
        let originalCols = direction == .left ? bitmap.height : bitmap.width
        let rows = direction == .left ? bitmap.width : bitmap.height
        let cols = (originalCols + 7) / 8 * 8

        func isBlack(col: Int, row: Int) -> Bool {
            switch direction {
            case .top: bitmap[col, row]
            case .left: bitmap[row, bitmap.height - 1 - col]
            }
        }

        var out: [EncodedImage.Row] = []
        var last: (data: [UInt8]?, index: Int)? = nil

        for row in 0..<rows {
            var data = [UInt8](repeating: 0, count: cols / 8)
            var black = 0
            for col in 0..<originalCols where isBlack(col: col, row: row) {
                data[col / 8] |= 1 << (7 - UInt8(col % 8))
                black += 1
            }
            let rowData: [UInt8]? = black == 0 ? nil : data

            if let last, last.data == rowData, out[last.index].repeatCount < 255 {
                switch out[last.index] {
                case .void(let n, let r): out[last.index] = .void(rowNumber: n, repeat: r + 1)
                case .pixels(let n, let r, let d, let b): out[last.index] = .pixels(rowNumber: n, repeat: r + 1, data: d, blackCount: b)
                case .check: break
                }
            } else {
                out.append(rowData == nil ? .void(rowNumber: row, repeat: 1) : .pixels(rowNumber: row, repeat: 1, data: data, blackCount: black))
                last = (rowData, out.count - 1)
            }

            if row % 200 == 199 {
                out.append(.check(rowNumber: row))
                last = nil
            }
        }

        return EncodedImage(cols: cols, rows: rows, rowsData: out)
    }
}

extension EncodedImage.Row {
    var repeatCount: Int {
        switch self {
        case .void(_, let r), .pixels(_, let r, _, _): r
        case .check: 0
        }
    }
}
