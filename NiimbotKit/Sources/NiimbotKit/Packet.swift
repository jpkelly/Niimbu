import Foundation

/// A NIIMBOT protocol packet: `55 55 | cmd | len | data… | xor checksum | AA AA`.
public struct NiimbotPacket: Equatable, Sendable {
    public static let head: [UInt8] = [0x55, 0x55]
    public static let tail: [UInt8] = [0xAA, 0xAA]

    public var command: UInt8
    public var data: [UInt8]
    /// Response command ids that complete this request. Empty means no response is expected.
    public var responseIds: Set<UInt8>

    public init(command: UInt8, data: [UInt8], responseIds: Set<UInt8> = []) {
        self.command = command
        self.data = data
        self.responseIds = responseIds
    }

    public var expectsResponse: Bool { !responseIds.isEmpty }

    public var checksum: UInt8 {
        data.reduce(command ^ UInt8(data.count), ^)
    }

    public func toBytes() -> [UInt8] {
        var out = Self.head + [command, UInt8(data.count)] + data + [checksum] + Self.tail
        if command == RequestCommand.connect.rawValue {
            // The connect packet is prefixed with 0x03.
            out.insert(0x03, at: 0)
        }
        return out
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 7 else { throw NiimbotError.malformedPacket("too short (\(bytes.count) bytes)") }
        guard Array(bytes[0..<2]) == Self.head else { throw NiimbotError.malformedPacket("invalid head") }
        let length = Int(bytes[3])
        guard bytes.count == 7 + length else { throw NiimbotError.malformedPacket("invalid size") }
        guard Array(bytes[(5 + length)...]) == Self.tail else { throw NiimbotError.malformedPacket("invalid tail") }
        self.init(command: bytes[2], data: Array(bytes[4..<(4 + length)]))
        guard checksum == bytes[4 + length] else { throw NiimbotError.malformedPacket("invalid checksum") }
    }

    public var hex: String { toBytes().hexString }
}

/// Accumulates incoming bytes (BLE notifications may split or merge packets) and yields whole packets.
public struct PacketReassembler: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func reset() { buffer.removeAll() }

    public mutating func append(_ bytes: [UInt8]) -> [NiimbotPacket] {
        buffer += bytes
        var packets: [NiimbotPacket] = []

        while true {
            // Resynchronise on the next packet head if there is garbage in front.
            guard let start = Self.indexOfHead(in: buffer) else {
                // Keep a trailing 0x55 in case it is the first half of a head.
                buffer = buffer.last == 0x55 ? [0x55] : []
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 4 else { break }

            let total = 7 + Int(buffer[3])
            guard buffer.count >= total else { break }

            if let packet = try? NiimbotPacket(bytes: Array(buffer[0..<total])) {
                packets.append(packet)
                buffer.removeFirst(total)
            } else {
                // Corrupt packet: skip this head and look for the next one.
                buffer.removeFirst(2)
            }
        }
        return packets
    }

    private static func indexOfHead(in buffer: [UInt8]) -> Int? {
        guard buffer.count >= 2 else { return nil }
        for i in 0..<(buffer.count - 1) where buffer[i] == 0x55 && buffer[i + 1] == 0x55 {
            return i
        }
        return nil
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}

func u16(_ value: Int) -> [UInt8] {
    [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}
