import Foundation

/// Which packet sequence a printer needs. See niimbluelib's print_tasks.
public enum PrintTaskKind: String, Sendable {
    /// Classic D11/D110.
    case d110
    /// B1, D110 M (protocol < 4) and similar.
    case b1
    /// D110 M with protocol v4+ and newer printers.
    case d110mV4
}

public struct PrinterModel: Equatable, Sendable {
    public let name: String
    public let ids: [Int]
    public let dpi: Int
    public let direction: PrintDirection
    public let printheadPixels: Int
    public let labelTypes: [LabelType]
    public let densityRange: ClosedRange<Int>
    public let defaultDensity: Int

    public var dotsPerMm: Double { Double(dpi) / 25.4 }

    func printTask(protocolVersion: Int) -> PrintTaskKind? {
        switch name {
        case "D110_M": protocolVersion >= 4 ? .d110mV4 : .b1
        case "D11", "D110", "D11S", "B21S": .d110
        case "B1", "N1", "D101", "M2_H": .b1
        case "D11_H", "B21_PRO", "B1_PRO", "C1": .d110mV4
        default: protocolVersion >= 4 ? .d110mV4 : nil
        }
    }

    public static func find(id: Int) -> PrinterModel? {
        all.first { $0.ids.contains(id) }
    }

    /// Subset of niimbluelib's model library. Only the D110 M has been the target of this app;
    /// the rest share print tasks but are untested.
    public static let all: [PrinterModel] = [
        PrinterModel(name: "D110_M", ids: [2320], dpi: 203, direction: .left, printheadPixels: 96,
                     labelTypes: [.withGaps, .transparent], densityRange: 1...5, defaultDensity: 3),
        PrinterModel(name: "D110", ids: [2304, 2305], dpi: 203, direction: .left, printheadPixels: 96,
                     labelTypes: [.withGaps, .transparent], densityRange: 1...3, defaultDensity: 2),
        PrinterModel(name: "D11", ids: [512], dpi: 203, direction: .left, printheadPixels: 96,
                     labelTypes: [.withGaps, .transparent], densityRange: 1...3, defaultDensity: 2),
        PrinterModel(name: "D11S", ids: [514], dpi: 203, direction: .left, printheadPixels: 96,
                     labelTypes: [.withGaps, .transparent], densityRange: 1...3, defaultDensity: 2),
        PrinterModel(name: "D11_H", ids: [528], dpi: 300, direction: .left, printheadPixels: 142,
                     labelTypes: [.withGaps, .transparent], densityRange: 1...5, defaultDensity: 3),
        PrinterModel(name: "B1", ids: [4096], dpi: 203, direction: .top, printheadPixels: 384,
                     labelTypes: [.withGaps, .black, .transparent], densityRange: 1...5, defaultDensity: 3),
    ]
}
