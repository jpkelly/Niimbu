import Foundation

public enum PageColor: UInt8, Sendable {
    case single = 0
    case double = 1
}

/// Builds request packets. Ported from niimbluelib's PacketGenerator (MIT, MultiMote).
public enum PacketGenerator {
    static func make(_ cmd: RequestCommand, _ data: [UInt8] = [1]) -> NiimbotPacket {
        NiimbotPacket(command: cmd.rawValue, data: data, responseIds: cmd.responseIds)
    }

    public static func connect() -> NiimbotPacket { make(.connect) }
    public static func printerStatusData() -> NiimbotPacket { make(.printerStatusData) }
    public static func printerInfo(_ type: PrinterInfoType) -> NiimbotPacket { make(.printerInfo, [type.rawValue]) }
    public static func heartbeat(_ type: HeartbeatType) -> NiimbotPacket { make(.heartbeat, [type.rawValue]) }
    public static func rfidInfo() -> NiimbotPacket { make(.rfidInfo) }
    public static func paperInfo() -> NiimbotPacket { make(.getPaperInfo) }
    public static func printStatus() -> NiimbotPacket { make(.printStatus) }
    public static func setDensity(_ value: Int) -> NiimbotPacket { make(.setDensity, [UInt8(value)]) }
    public static func setLabelType(_ type: LabelType) -> NiimbotPacket { make(.setLabelType, [type.rawValue]) }
    public static func pageStart() -> NiimbotPacket { make(.pageStart) }
    public static func pageEnd() -> NiimbotPacket { make(.pageEnd) }
    public static func printEnd() -> NiimbotPacket { make(.printEnd) }
    public static func printClear() -> NiimbotPacket { make(.printClear) }
    public static func cancelPrint() -> NiimbotPacket { make(.cancelPrint) }
    /// `level` is 1–4; what each level means in minutes depends on the model.
    public static func setAutoShutdownTime(_ level: Int) -> NiimbotPacket { make(.setAutoShutdownTime, [UInt8(level)]) }
    public static func getSound(_ sound: PrinterSound) -> NiimbotPacket { make(.soundSettings, [2, sound.rawValue, 1]) }
    public static func setSound(_ sound: PrinterSound, on: Bool) -> NiimbotPacket {
        make(.soundSettings, [1, sound.rawValue, on ? 1 : 0])
    }
    public static func labelPositioningCalibration(_ value: UInt8) -> NiimbotPacket { make(.labelPositioningCalibration, [value]) }

    public static func setPageSize4b(rows: Int, cols: Int) -> NiimbotPacket {
        make(.setPageSize, u16(rows) + u16(cols))
    }

    public static func setPrintQuantity(_ quantity: Int) -> NiimbotPacket {
        make(.printQuantity, u16(quantity))
    }

    public static func setPageSize6b(rows: Int, cols: Int, copies: Int) -> NiimbotPacket {
        make(.setPageSize, u16(rows) + u16(cols) + u16(copies))
    }

    /// First seen on D110M v4.
    public static func setPageSize13b(rows: Int, cols: Int, copies: Int, cutHeight: Int = 0, cutType: UInt8 = 0,
                                      sendAll: UInt8 = 0, partHeight: Int = 0) -> NiimbotPacket {
        var data: [UInt8] = u16(rows) + u16(cols) + u16(copies)
        data += u16(cutHeight)
        data += [cutType, 0x00, sendAll]
        data += u16(partHeight)
        return make(.setPageSize, data)
    }

    public static func printStart1b() -> NiimbotPacket { make(.printStart) }

    public static func printStart7b(totalPages: Int, pageColor: PageColor = .single) -> NiimbotPacket {
        make(.printStart, u16(totalPages) + [0, 0, 0, 0, pageColor.rawValue])
    }

    /// First seen on D110M v4. `speed`: 0 = quality, 1 = fast.
    public static func printStart9b(totalPages: Int, pageColor: PageColor = .single, speed: UInt8 = 0) -> NiimbotPacket {
        make(.printStart, u16(totalPages) + [0, 0, 0, 0, pageColor.rawValue, speed, 0])
    }

    public static func printEmptyRows(row: Int, repeats: Int) -> NiimbotPacket {
        make(.printEmptyRow, u16(row) + [UInt8(repeats)])
    }

    public static func printBitmapRow(row: Int, repeats: Int, data: [UInt8], printheadPixels: Int) -> NiimbotPacket {
        let counts = pixelCounts(data, printheadPixels: printheadPixels)
        return make(.printBitmapRow, u16(row) + counts.parts + [UInt8(repeats)] + data)
    }

    /// Lists black pixel positions instead of the raw row. Used for rows with at most 6 black pixels.
    public static func printBitmapRowIndexed(row: Int, repeats: Int, data: [UInt8], printheadPixels: Int) -> NiimbotPacket {
        let counts = pixelCounts(data, printheadPixels: printheadPixels)
        var indexes: [UInt8] = []
        for (byteIndex, byte) in data.enumerated() {
            for bit in 0..<8 where byte & (1 << (7 - UInt8(bit))) != 0 {
                indexes += u16(byteIndex * 8 + bit)
            }
        }
        return make(.printBitmapRowIndexed, u16(row) + counts.parts + [UInt8(repeats)] + indexes)
    }

    public static func checkLine(_ row: Int) -> NiimbotPacket {
        make(.printerCheckLine, u16(row) + [0x01])
    }

    public static func imageData(_ image: EncodedImage, printheadPixels: Int, enableCheckLine: Bool = false) -> [NiimbotPacket] {
        image.rowsData.compactMap { row in
            switch row {
            case let .void(n, r):
                return printEmptyRows(row: n, repeats: r)
            case let .pixels(n, r, data, black):
                return black <= 6
                    ? printBitmapRowIndexed(row: n, repeats: r, data: data, printheadPixels: printheadPixels)
                    : printBitmapRow(row: n, repeats: r, data: data, printheadPixels: printheadPixels)
            case let .check(n):
                return enableCheckLine ? checkLine(n) : nil
            }
        }
    }

    /// The "black pixel count" section of bitmap packets: either per-third counts of the printhead,
    /// or a total count when the row does not fit three chunks.
    static func pixelCounts(_ data: [UInt8], printheadPixels: Int) -> (total: Int, parts: [UInt8]) {
        let chunkSize = printheadPixels / 8 / 3
        let split = chunkSize > 0 && data.count <= chunkSize * 3
        var total = 0
        var parts = [0, 0, 0]

        for (byteIndex, byte) in data.enumerated() {
            let bits = byte.nonzeroBitCount
            total += bits
            if split { parts[byteIndex / chunkSize] += bits }
        }

        if split {
            return (total, parts.map { UInt8(min($0, 255)) })
        }
        let bytes = u16(total)
        return (total, [0, bytes[1], bytes[0]])
    }
}
