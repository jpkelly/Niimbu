import Foundation

/// Reads big-endian values from packet payloads.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }
    func canRead(_ n: Int) -> Bool { remaining >= n }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> Int {
        try need(2)
        defer { offset += 2 }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { offset += n }
        return Array(bytes[offset..<(offset + n)])
    }

    /// One length byte followed by a UTF-8 string.
    mutating func vString() throws -> String {
        let n = Int(try u8())
        return String(decoding: try bytes(n), as: UTF8.self)
    }

    mutating func skip(_ n: Int) throws { _ = try bytes(n) }

    private func need(_ n: Int) throws {
        guard remaining >= n else { throw NiimbotError.malformedPacket("payload too short") }
    }
}

public struct PrintStatus: Equatable, Sendable {
    public var page: Int
    public var pagePrintProgress: Int
    public var pageFeedProgress: Int
    public var error: UInt8
}

public struct RfidInfo: Equatable, Sendable {
    public var tagPresent: Bool
    public var uuid: String = ""
    public var barCode: String = ""
    public var serialNumber: String = ""
    public var totalLabels: Int = -1
    public var usedLabels: Int = -1
    public var labelType: LabelType = .invalid

    public var remainingLabels: Int? {
        tagPresent && totalLabels >= 0 && usedLabels >= 0 ? max(totalLabels - usedLabels, 0) : nil
    }
}

public struct PaperInfo: Equatable, Sendable {
    public var labelType: LabelType
    /// Millimetres.
    public var width: Double
    public var height: Double
    public var gapHeight: Double
}

public struct HeartbeatData: Equatable, Sendable {
    public var batteryPercent: Int?
    public var lidClosed: Bool?
    public var paperInserted: Bool?
    public var paperRfidSuccess: Bool?
}

public struct PrinterHeadInfo: Equatable, Sendable {
    public var hardwareVersion: String
    public var softwareVersion: String
    public var printheadWidth: Int
}

/// Response parsers. Ported from niimbluelib's PacketParser (MIT, MultiMote).
public enum ResponseParser {
    public static func connectResult(_ p: NiimbotPacket) throws -> ConnectResult {
        guard let b = p.data.first else { throw NiimbotError.malformedPacket("empty connect response") }
        return ConnectResult(rawValue: b) ?? .connected
    }

    /// Protocol version from PrinterStatusData (v3 printers).
    public static func protocolVersion(_ p: NiimbotPacket) -> Int {
        guard p.data.count >= 13 else { return 0 }
        let n = Int(p.data[11]) * 100 + Int(p.data[12])
        switch n {
        case 204..<300: return 3
        case 300..<302: return 4
        case 302...: return 5
        default: return 0
        }
    }

    public static func modelId(_ p: NiimbotPacket) throws -> Int {
        switch p.data.count {
        case 1: return Int(p.data[0]) << 8
        case 2: return Int(p.data[0]) << 8 | Int(p.data[1])
        default: throw NiimbotError.malformedPacket("model id")
        }
    }

    public static func battery(_ p: NiimbotPacket) throws -> Int {
        guard p.data.count == 1 else { throw NiimbotError.malformedPacket("battery") }
        let v = Int(p.data[0])
        return v <= 4 ? v * 25 : v
    }

    public static func serialNumber(_ p: NiimbotPacket) -> String {
        if p.data.count >= 8 { return String(decoding: p.data, as: UTF8.self) }
        if p.data.count >= 4 { return p.data[0..<4].map { String(format: "%02X", $0) }.joined() }
        return "-1"
    }

    public static func printerHeadInfo(_ p: NiimbotPacket) throws -> PrinterHeadInfo {
        guard p.data.count == 10 else { throw NiimbotError.malformedPacket("printer info heartbeat") }
        func version(_ h: UInt8, _ l: UInt8) -> String { String(format: "%.2f", Double(l) / 100 + Double(h)) }
        return PrinterHeadInfo(
            hardwareVersion: version(p.data[0], p.data[1]),
            softwareVersion: version(p.data[2], p.data[3]),
            printheadWidth: Int(p.data[4]) << 8 | Int(p.data[5])
        )
    }

    public static func printStatus(_ p: NiimbotPacket) throws -> PrintStatus {
        var r = ByteReader(p.data)
        let page = try r.u16()
        let printProgress = Int(try r.u8())
        let feedProgress = Int(try r.u8())
        var error: UInt8 = 0
        if p.data.count == 10 {
            try r.skip(2)
            error = try r.u8()
        }
        return PrintStatus(page: page, pagePrintProgress: printProgress, pageFeedProgress: feedProgress, error: error)
    }

    public static func rfidInfo(_ p: NiimbotPacket) throws -> RfidInfo {
        guard p.data.count > 1 else { return RfidInfo(tagPresent: false) }
        var r = ByteReader(p.data)
        var info = RfidInfo(tagPresent: true)
        info.uuid = try r.bytes(8).map { String(format: "%02x", $0) }.joined()
        info.barCode = try r.vString()
        info.serialNumber = try r.vString()
        info.totalLabels = try r.u16()
        info.usedLabels = try r.u16()
        info.labelType = LabelType(rawValue: try r.u8()) ?? .invalid
        return info
    }

    /// Returns nil when the printer sends the short (unknown) form.
    public static func paperInfo(_ p: NiimbotPacket) throws -> PaperInfo? {
        guard p.data.count == 18 else { return nil }
        var r = ByteReader(p.data)
        _ = try r.u16() // gap height, px
        _ = try r.u16() // total height, px
        let type = LabelType(rawValue: try r.u8()) ?? .invalid
        let gap = Double(try r.u16()) / 10
        let total = Double(try r.u16()) / 10
        _ = try r.u16() // width, px
        let width = Double(try r.u16()) / 10
        return PaperInfo(labelType: type, width: width, height: total, gapHeight: gap)
    }

    public static func heartbeat(_ p: NiimbotPacket, modelId: Int?) throws -> HeartbeatData {
        var r = ByteReader(p.data)
        var info = HeartbeatData()

        switch p.command {
        case ResponseCommand.heartbeatAdvanced2.rawValue:
            guard p.data.count >= 9 else { throw NiimbotError.malformedPacket("heartbeat") }
            try r.skip(2)
            info.batteryPercent = Int(try r.u8())
            try r.skip(1) // temperature
            info.lidClosed = try r.u8() == 0
            info.paperInserted = try r.u8() == 0
            info.paperRfidSuccess = try r.u8() != 0

        case ResponseCommand.heartbeatAdvanced1.rawValue:
            switch p.data.count {
            case 10:
                try r.skip(8)
                info.lidClosed = try r.u8() == 0
                info.batteryPercent = Int(try r.u8())
            case 13, 19:
                try r.skip(p.data.count == 13 ? 9 : 15)
                info.lidClosed = try r.u8() == 0
                info.batteryPercent = Int(try r.u8())
                info.paperInserted = try r.u8() == 0
                info.paperRfidSuccess = try r.u8() != 0
            case 20:
                try r.skip(18)
                info.paperInserted = try r.u8() == 0
                info.paperRfidSuccess = try r.u8() != 0
            default:
                throw NiimbotError.malformedPacket("heartbeat length \(p.data.count)")
            }
            let invertedLidModels = [512, 514, 513, 2304, 1792, 3584, 5120, 2560, 3840, 4352, 272, 273, 274]
            if let modelId, invertedLidModels.contains(modelId), let lid = info.lidClosed {
                info.lidClosed = !lid
            }

        default:
            throw NiimbotError.unexpectedResponse(String(format: "heartbeat 0x%02x", p.command))
        }

        if let b = info.batteryPercent, b <= 4 { info.batteryPercent = b * 25 }
        return info
    }

    public static func bool(_ p: NiimbotPacket) -> Bool {
        p.data.count == 1 && p.data[0] == 1
    }
}
