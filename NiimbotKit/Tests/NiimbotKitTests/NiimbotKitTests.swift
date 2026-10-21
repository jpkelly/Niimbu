import Foundation
import Testing
@testable import NiimbotKit

@Suite struct PacketTests {
    @Test func encodesConnectWithPrefix() {
        #expect(PacketGenerator.connect().toBytes() == bytes("03 5555 c1 01 01 c1 aaaa"))
    }

    @Test func encodesMatchCapture() {
        #expect(PacketGenerator.printerInfo(.modelId).toBytes() == bytes("5555 40 01 08 49 aaaa"))
        #expect(PacketGenerator.heartbeat(.advanced2).toBytes() == bytes("5555 dc 01 04 d9 aaaa"))
        #expect(PacketGenerator.printerStatusData().toBytes() == bytes("5555 a5 01 01 a5 aaaa"))
    }

    @Test func decodesAndValidatesChecksum() throws {
        let p = try NiimbotPacket(bytes: bytes("5555 48 02 0910 53 aaaa"))
        #expect(p.command == 0x48)
        #expect(p.data == [0x09, 0x10])
        #expect(throws: NiimbotError.self) { try NiimbotPacket(bytes: bytes("5555 48 02 0910 54 aaaa")) }
    }

    @Test func reassemblesSplitAndMergedNotifications() {
        var r = PacketReassembler()
        let a = bytes("5555 c2 01 03 c0 aaaa")
        let b = bytes("5555 4a 01 04 4f aaaa")
        #expect(r.append(Array(a[0..<3])).isEmpty)
        #expect(r.append(Array(a[3...]) + Array(b[0..<5])).count == 1)
        let rest = r.append(Array(b[5...]))
        #expect(rest.map(\.command) == [0x4a])
    }

    @Test func skipsGarbageBeforeHead() {
        var r = PacketReassembler()
        let packets = r.append([0x00, 0x13] + bytes("5555 4a 01 04 4f aaaa"))
        #expect(packets.map(\.command) == [0x4a])
    }

    @Test func pageSize13bLayout() {
        let p = PacketGenerator.setPageSize13b(rows: 240, cols: 96, copies: 2)
        #expect(p.data == [0x00, 0xF0, 0x00, 0x60, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func printStart9bLayout() {
        let p = PacketGenerator.printStart9b(totalPages: 3, speed: 1)
        #expect(p.data == [0x00, 0x03, 0, 0, 0, 0, 0, 1, 0])
    }
}

@Suite struct ParserTests {
    @Test func protocolVersionFromStatusData() throws {
        let p = try NiimbotPacket(bytes: bytes("5555 b5 10 3030232800c80000000a00030112ee00 92 aaaa"))
        #expect(ResponseParser.protocolVersion(p) == 4)
    }

    @Test func printerHeadInfo() throws {
        let p = try NiimbotPacket(bytes: bytes("5555 de 0a 04010417006002020100 a3 aaaa"))
        let info = try ResponseParser.printerHeadInfo(p)
        #expect(info == PrinterHeadInfo(hardwareVersion: "4.01", softwareVersion: "4.23", printheadWidth: 96))
    }

    @Test func heartbeatAdvanced2() throws {
        let p = try NiimbotPacket(bytes: bytes("5555 d9 0b 0fd1044d00000000000000 45 aaaa"))
        let hb = try ResponseParser.heartbeat(p, modelId: 2320)
        #expect(hb.batteryPercent == 100)
        #expect(hb.lidClosed == true)
        #expect(hb.paperRfidSuccess == false)
    }

    @Test func rfidFromB21ProCapture() throws {
        let p = try NiimbotPacket(bytes: bytes("5555 1b 2a 881dce944a0c10800930333033323531323010504330493131353432323030303731320072000201005f 44 aaaa"))
        let info = try ResponseParser.rfidInfo(p)
        #expect(info.tagPresent)
        #expect(info.barCode == "030325120")
        #expect(info.serialNumber == "PC0I115422000712")
        #expect(info.totalLabels == 114)
        #expect(info.usedLabels == 2)
        #expect(info.labelType == .withGaps)
        #expect(info.remainingLabels == 112)
    }

    @Test func rfidWithoutTag() throws {
        let p = NiimbotPacket(command: 0x1b, data: [0x00])
        #expect(try ResponseParser.rfidInfo(p).tagPresent == false)
    }

    @Test func printStatusWithError() throws {
        let p = NiimbotPacket(command: 0xb3, data: [0, 1, 50, 20, 0, 0, 0x02, 0, 0, 0])
        let s = try ResponseParser.printStatus(p)
        #expect(s.page == 1)
        #expect(s.pagePrintProgress == 50)
        #expect(s.error == 0x02)
    }
}

@Suite struct ImageEncoderTests {
    @Test func leftDirectionRotatesClockwise() {
        // 16x8 image (labels are wider than tall); one black pixel at top-left.
        var bmp = MonoBitmap(width: 16, height: 8)
        bmp[0, 0] = true
        let img = ImageEncoder.encode(bmp, direction: .left)
        #expect(img.cols == 8)
        #expect(img.rows == 16)
        // Top-left of the label ends up at row 0, last printhead column.
        guard case let .pixels(n, r, data, black) = img.rowsData[0] else {
            Issue.record("expected pixels row"); return
        }
        #expect(n == 0 && r == 1 && black == 1)
        #expect(data == [0b0000_0001])
        #expect(img.rowsData[1] == .void(rowNumber: 1, repeat: 15))
    }

    @Test func topDirectionPadsToByte() {
        var bmp = MonoBitmap(width: 10, height: 2)
        bmp[9, 0] = true
        bmp[9, 1] = true
        let img = ImageEncoder.encode(bmp, direction: .top)
        #expect(img.cols == 16)
        #expect(img.rowsData == [.pixels(rowNumber: 0, repeat: 2, data: [0, 0b0100_0000], blackCount: 1)])
    }

    @Test func capsRepeatAt255AndAddsCheckLines() {
        let img = ImageEncoder.encode(MonoBitmap(width: 8, height: 600), direction: .top)
        for row in img.rowsData { #expect(row.repeatCount <= 255) }
        #expect(img.rowsData.contains(.check(rowNumber: 199)))
        let total = img.rowsData.reduce(0) { $0 + $1.repeatCount }
        #expect(total == 600)
    }

    @Test func pixelCountsSplitForD110Head() {
        // 96px head: three 4-byte chunks.
        var data = [UInt8](repeating: 0, count: 12)
        data[0] = 0xFF; data[5] = 0x0F; data[11] = 0x01
        let c = PacketGenerator.pixelCounts(data, printheadPixels: 96)
        #expect(c.total == 13)
        #expect(c.parts == [8, 4, 1])
    }

    @Test func indexedRowForSparsePixels() {
        let p = PacketGenerator.printBitmapRowIndexed(row: 0x7e, repeats: 1, data: [0, 0, 0, 0, 0b1000_0000, 0, 0, 0, 0, 0, 0, 0], printheadPixels: 96)
        #expect(p.command == 0x83)
        #expect(p.data == [0x00, 0x7e, 0, 1, 0, 1, 0x00, 0x20])
    }
}

@MainActor
@Suite struct ClientTests {
    @Test func connectsToRecordedD110M() async throws {
        let transport = DumpTransport(dump: d110mV4Dump)
        let client = NiimbotClient(transport: transport)
        client.packetInterval = .zero
        try await client.start()
        client.disconnect()

        #expect(client.info.modelId == 2320)
        #expect(client.info.model?.name == "D110_M")
        #expect(client.info.protocolVersion == 4)
        #expect(client.info.serial == "H322062548")
        #expect(client.info.hardwareVersion == "4.01")
        #expect(client.info.softwareVersion == "4.23")
        #expect(client.info.printheadPixels == 96)
        #expect(client.info.batteryPercent == 100)
        #expect(client.info.model?.printTask(protocolVersion: 4) == .d110mV4)
    }

    @Test func readsRollFromRfid() async throws {
        let transport = FakePrinterTransport()
        let client = NiimbotClient(transport: transport)
        client.packetInterval = .zero
        try await client.start()
        client.disconnect()

        let rfid = try #require(client.consumables.rfid)
        #expect(rfid.barCode == "6972842743589")
        #expect(rfid.remainingLabels == 200)
        #expect(client.consumables.labelType == .withGaps)
        #expect(client.consumables.paper == nil)
    }

    @Test func printsWithD110MV4Sequence() async throws {
        let transport = FakePrinterTransport()
        let client = NiimbotClient(transport: transport)
        client.packetInterval = .zero
        try await client.start()

        var bmp = MonoBitmap(width: 240, height: 96)
        for x in 0..<240 { bmp[x, 48] = true }
        let before = transport.sent.count
        try await client.print(bmp, options: PrintOptions(density: 3, labelType: .withGaps, copies: 2))
        client.disconnect()

        let cmds = transport.sent[before...].map(\.command)
        let expectedStart: [RequestCommand] = [.setLabelType, .setDensity, .printStart, .printStatus, .setPageSize]
        #expect(Array(cmds.prefix(5)) == expectedStart.map(\.rawValue))
        #expect(transport.sent[before + 2].data == [0, 2, 0, 0, 0, 0, 0, 0, 0])
        #expect(transport.sent[before + 4].data.prefix(6) == [0, 240, 0, 96, 0, 2])
        #expect(cmds.contains(RequestCommand.pageEnd.rawValue))
        #expect(cmds.contains(RequestCommand.printEnd.rawValue))
        // The horizontal line is the same on every row: indexed packets (1 black pixel), split once by the row-199 check line.
        #expect(cmds.filter { $0 == RequestCommand.printBitmapRowIndexed.rawValue }.count == 2)
    }

    @Test func printsSeparatePagesInOneJob() async throws {
        let transport = FakePrinterTransport()
        let client = NiimbotClient(transport: transport)
        client.packetInterval = .zero
        try await client.start()

        let before = transport.sent.count
        let pages = (0..<3).map { _ in MonoBitmap(width: 240, height: 96) }
        try await client.print(pages: pages, options: PrintOptions(density: 3, labelType: .withGaps, copies: 1))
        client.disconnect()

        let sent = transport.sent[before...]
        let start = try #require(sent.first { $0.command == RequestCommand.printStart.rawValue })
        #expect(start.data.prefix(2) == [0, 3])
        let pageSizes = sent.filter { $0.command == RequestCommand.setPageSize.rawValue }
        #expect(pageSizes.count == 3)
        #expect(pageSizes.allSatisfy { $0.data.prefix(6) == [0, 240, 0, 96, 0, 1] })
        #expect(sent.filter { $0.command == RequestCommand.pageEnd.rawValue }.count == 3)
    }

    @Test func usesB1SequenceForOldProtocol() async throws {
        let transport = FakePrinterTransport()
        transport.statusData = bytes("3030232800c80000000a00021012ee00") // v3
        let client = NiimbotClient(transport: transport)
        client.packetInterval = .zero
        try await client.start()
        #expect(client.info.protocolVersion == 3)

        let before = transport.sent.count
        try await client.print(MonoBitmap(width: 240, height: 96), options: PrintOptions(density: 3))
        client.disconnect()

        let cmds = Array(transport.sent[before...].map(\.command).prefix(5))
        let expected: [RequestCommand] = [.setDensity, .setLabelType, .printStart, .pageStart, .setPageSize]
        #expect(cmds == expected.map(\.rawValue))
    }

    @Test func rejectsImageWiderThanPrinthead() async throws {
        let transport = FakePrinterTransport()
        let client = NiimbotClient(transport: transport)
        client.packetInterval = .zero
        try await client.start()
        await #expect(throws: NiimbotError.self) {
            try await client.print(MonoBitmap(width: 240, height: 120), options: PrintOptions(density: 3))
        }
        client.disconnect()
    }
}
