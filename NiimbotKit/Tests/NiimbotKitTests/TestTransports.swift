import Foundation
@testable import NiimbotKit

func bytes(_ hex: String) -> [UInt8] {
    let clean = hex.replacingOccurrences(of: " ", with: "")
    return stride(from: 0, to: clean.count, by: 2).map {
        let start = clean.index(clean.startIndex, offsetBy: $0)
        return UInt8(clean[start..<clean.index(start, offsetBy: 2)], radix: 16)!
    }
}

/// Replays a recorded packet exchange: each request that matches a `>>` line gets the following `<<` line.
/// Unknown requests get `In_NotSupported`, like niimbluelib's virtual client.
@MainActor
final class DumpTransport: NiimbotTransport {
    var onReceive: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    private var responses: [[UInt8]: [UInt8]] = [:]
    private(set) var sent: [[UInt8]] = []

    init(dump: String) {
        var request: [UInt8]?
        for line in dump.split(separator: "\n") {
            let text = line.replacingOccurrences(of: #"\(.*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(">>") {
                request = bytes(String(text.dropFirst(2)))
            } else if text.hasPrefix("<<"), let r = request {
                // First response wins; later identical requests (heartbeats) reuse it.
                if responses[r] == nil { responses[r] = bytes(String(text.dropFirst(2))) }
                request = nil
            }
        }
    }

    func write(_ data: Data) async throws {
        let request = [UInt8](data)
        sent.append(request)
        let response = responses[request] ?? bytes("5555 00 01 01 00 aaaa")
        Task { @MainActor in self.onReceive?(Data(response)) }
    }

    func close() { onDisconnect?(nil) }
}

/// Answers like a printer: acknowledges every command and reports print progress as complete.
@MainActor
final class FakePrinterTransport: NiimbotTransport {
    var onReceive: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    private(set) var sent: [NiimbotPacket] = []
    private var totalPages = 1
    var modelId: [UInt8] = [0x09, 0x10]
    var statusData = bytes("3030232800c80000000a00030112ee00")
    /// Split replies into 3-byte notifications to exercise reassembly.
    var fragmentReplies = true

    func write(_ data: Data) async throws {
        var raw = [UInt8](data)
        if raw.first == 0x03 { raw.removeFirst() }
        let packet = try NiimbotPacket(bytes: raw)
        sent.append(packet)

        guard let cmd = RequestCommand(rawValue: packet.command) else { return }
        let reply: (ResponseCommand, [UInt8])?
        switch cmd {
        case .connect: reply = (.connect, [0x03])
        case .printerStatusData: reply = (.printerStatusData, statusData)
        case .printerInfo:
            let type = PrinterInfoType(rawValue: packet.data[0])
            let data: [UInt8] = switch type {
            case .modelId: modelId
            case .serialNumber: Array("H322062548".utf8)
            case .batteryChargeLevel: [0x04]
            default: [0x00]
            }
            sendReply(NiimbotPacket(command: 0x40 + packet.data[0], data: data))
            return
        case .heartbeat:
            reply = packet.data[0] == HeartbeatType.printerInfo.rawValue
                ? (.heartbeatBasic, bytes("04010417006002020100"))
                : (.heartbeatAdvanced2, bytes("0fd1044d00000000000000"))
        case .rfidInfo:
            // A genuine 30x12mm roll, 210 labels, 10 used, with gaps.
            var d = bytes("881dce944a0c1080")
            d += [13] + Array("6972842743589".utf8)
            d += [8] + Array("PC0I1154".utf8)
            d += u16(210) + u16(10) + [0x01]
            reply = (.rfidInfo, d)
        case .getPaperInfo: reply = (.notSupported, [0x01])
        case .printStart:
            totalPages = Int(packet.data[0]) << 8 | Int(packet.data[1])
            reply = (.printStart, [0x01])
        case .printStatus: reply = (.printStatus, u16(totalPages) + [100, 100])
        case .setDensity: reply = (.setDensity, [0x01])
        case .setLabelType: reply = (.setLabelType, [0x01])
        case .setPageSize: reply = (.setPageSize, [0x01])
        case .pageStart: reply = (.pageStart, [0x01])
        case .pageEnd: reply = (.pageEnd, [0x01])
        case .printEnd: reply = (.printEnd, [0x01])
        default: reply = nil
        }
        if let (rc, data) = reply {
            sendReply(NiimbotPacket(command: rc.rawValue, data: data))
        }
    }

    private func sendReply(_ p: NiimbotPacket) {
        let raw = p.toBytes()
        let chunks = fragmentReplies ? stride(from: 0, to: raw.count, by: 3).map { Array(raw[$0..<min($0 + 3, raw.count)]) } : [raw]
        Task { @MainActor in
            for c in chunks { self.onReceive?(Data(c)) }
        }
    }

    func close() { onDisconnect?(nil) }
}
