import Foundation

public struct PrinterInfo: Equatable, Sendable {
    public var modelId: Int?
    public var model: PrinterModel?
    public var protocolVersion = 0
    public var serial: String?
    public var hardwareVersion: String?
    public var softwareVersion: String?
    public var printheadPixels: Int?
    public var batteryPercent: Int?

    public init() {}

    public var modelName: String {
        model?.name.replacingOccurrences(of: "_", with: " ") ?? modelId.map { "Unknown (\($0))" } ?? "Unknown"
    }
}

/// What the printer knows about the loaded roll.
public struct Consumables: Equatable, Sendable {
    public var rfid: RfidInfo?
    public var paper: PaperInfo?

    public init(rfid: RfidInfo? = nil, paper: PaperInfo? = nil) {
        self.rfid = rfid
        self.paper = paper
    }

    /// Label type from the RFID tag, falling back to paper info.
    public var labelType: LabelType? {
        if let t = rfid?.labelType, t != .invalid { return t }
        if let t = paper?.labelType, t != .invalid { return t }
        return nil
    }
}

public struct PrintOptions: Sendable {
    public var density: Int
    public var labelType: LabelType
    public var copies: Int
    /// D110 M v4 only: 0 = quality, 1 = fast.
    public var speed: UInt8

    public init(density: Int, labelType: LabelType = .withGaps, copies: Int = 1, speed: UInt8 = 0) {
        self.density = density
        self.labelType = labelType
        self.copies = copies
        self.speed = speed
    }
}

public enum PrintPhase: Equatable, Sendable {
    case sending(percent: Int)
    case printing(page: Int, of: Int, percent: Int)
}

public enum NiimbotClientEvent: Sendable {
    case heartbeat(HeartbeatData)
    case consumablesChanged(Consumables)
    case disconnected(String?)
    case log(String)
}

/// Talks the NIIMBOT protocol over a transport. All state lives on the main actor;
/// the work is I/O-bound, so this keeps CoreBluetooth callbacks simple.
@MainActor
public final class NiimbotClient {
    public private(set) var info = PrinterInfo()
    public private(set) var consumables = Consumables()
    public private(set) var lastHeartbeat: HeartbeatData?
    public var onEvent: ((NiimbotClientEvent) -> Void)?
    /// Log every packet sent and received.
    public var verbose = false

    private let transport: NiimbotTransport
    private let lock = AsyncLock()
    private var reassembler = PacketReassembler()
    private var waiters: [ResponseWaiter] = []
    private var heartbeatTask: Task<Void, Never>?
    private var isPrinting = false
    /// Delay before every write; some printers drop packets sent back-to-back (niimblue#5).
    var packetInterval: Duration = .milliseconds(10)

    public init(transport: NiimbotTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] data in self?.receive(data) }
        transport.onDisconnect = { [weak self] error in self?.handleDisconnect(error) }
    }

    // MARK: - Packet exchange

    private func receive(_ data: Data) {
        for packet in reassembler.append([UInt8](data)) {
            if verbose { log("<< \(packet.hex)") }
            dispatch(packet)
        }
    }

    private func dispatch(_ packet: NiimbotPacket) {
        let isError = packet.command == ResponseCommand.printError.rawValue
            || packet.command == ResponseCommand.notSupported.rawValue
        guard let waiter = waiters.first(where: { isError || $0.ids.contains(packet.command) }) else { return }
        waiters.removeAll { $0 === waiter }

        if packet.command == ResponseCommand.printError.rawValue {
            waiter.complete(.failure(NiimbotError.printError(packet.data.first ?? 0)))
        } else if packet.command == ResponseCommand.notSupported.rawValue {
            waiter.complete(.failure(NiimbotError.notSupported))
        } else {
            waiter.complete(.success(packet))
        }
    }

    private func write(_ packet: NiimbotPacket) async throws {
        try await Task.sleep(for: packetInterval)
        if verbose { log(">> \(packet.hex)") }
        try await transport.write(Data(packet.toBytes()))
    }

    /// Sends a packet and waits for its response. One-way packets return nil.
    @discardableResult
    public func send(_ packet: NiimbotPacket, timeout: Duration = .seconds(1)) async throws -> NiimbotPacket? {
        try await lock.run {
            guard packet.expectsResponse else {
                try await write(packet)
                return nil
            }

            let waiter = ResponseWaiter(ids: packet.responseIds)
            waiters.append(waiter)
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self, !waiter.isDone else { return }
                self.waiters.removeAll { $0 === waiter }
                waiter.complete(.failure(NiimbotError.timeout(String(format: "command 0x%02x", packet.command))))
            }
            defer { timer.cancel() }

            do {
                try await write(packet)
            } catch {
                waiters.removeAll { $0 === waiter }
                waiter.complete(.failure(error))
            }
            return try await waiter.value()
        }
    }

    /// Sends without waiting even if the command normally has a response.
    private func sendOneWay(_ packet: NiimbotPacket) async throws {
        var p = packet
        p.responseIds = []
        try await send(p)
    }

    private func request(_ packet: NiimbotPacket, timeout: Duration = .seconds(1)) async throws -> NiimbotPacket {
        guard let response = try await send(packet, timeout: timeout) else {
            throw NiimbotError.unexpectedResponse("no response")
        }
        return response
    }

    // MARK: - Connection

    /// Negotiates the protocol and reads printer information. Call once after the transport opens.
    public func start() async throws {
        let result = try ResponseParser.connectResult(try await request(PacketGenerator.connect()))
        switch result {
        case .connectedNew: info.protocolVersion = 1
        case .connectedV3:
            info.protocolVersion = ResponseParser.protocolVersion(try await request(PacketGenerator.printerStatusData()))
        case .disconnect, .firmwareErrors:
            throw NiimbotError.unexpectedResponse("connect refused (\(result))")
        case .connected: break
        }

        let modelId = try ResponseParser.modelId(try await request(PacketGenerator.printerInfo(.modelId)))
        info.modelId = modelId
        info.model = PrinterModel.find(id: modelId)

        info.serial = try? ResponseParser.serialNumber(await request(PacketGenerator.printerInfo(.serialNumber)))
        info.batteryPercent = try? ResponseParser.battery(await request(PacketGenerator.printerInfo(.batteryChargeLevel)))
        if let head = try? ResponseParser.printerHeadInfo(await request(PacketGenerator.heartbeat(.printerInfo))) {
            info.hardwareVersion = head.hardwareVersion
            info.softwareVersion = head.softwareVersion
            info.printheadPixels = head.printheadWidth
        }
        log("Connected: \(info.modelName), protocol v\(info.protocolVersion), firmware \(info.softwareVersion ?? "?")")

        await refreshConsumables()
        startHeartbeat()
    }

    public func disconnect() {
        heartbeatTask?.cancel()
        transport.close()
    }

    private func handleDisconnect(_ error: Error?) {
        heartbeatTask?.cancel()
        for waiter in waiters { waiter.complete(.failure(NiimbotError.notConnected)) }
        waiters.removeAll()
        reassembler.reset()
        onEvent?(.disconnected(error?.localizedDescription))
    }

    // MARK: - Heartbeat & consumables

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if !self.isPrinting { await self.heartbeat() }
            }
        }
    }

    private func heartbeat() async {
        let type: HeartbeatType = info.protocolVersion >= 3 ? .advanced2 : .advanced1
        guard let packet = try? await request(PacketGenerator.heartbeat(type), timeout: .milliseconds(500)),
              let data = try? ResponseParser.heartbeat(packet, modelId: info.modelId) else { return }

        let previous = lastHeartbeat
        lastHeartbeat = data
        if let b = data.batteryPercent { info.batteryPercent = b }
        onEvent?(.heartbeat(data))

        // Lid opened/closed or the RFID read changed: the roll was probably swapped.
        if let previous, previous.lidClosed != data.lidClosed || previous.paperRfidSuccess != data.paperRfidSuccess
            || previous.paperInserted != data.paperInserted {
            log("Heartbeat: lid \(flag(data.lidClosed, "closed", "open")), paper \(flag(data.paperInserted, "in", "out")), "
                + "RFID \(flag(data.paperRfidSuccess, "ok", "failed")) [\(hex(packet.data))]")
            await refreshConsumables()
        }
    }

    private func flag(_ value: Bool?, _ yes: String, _ no: String) -> String {
        value.map { $0 ? yes : no } ?? "?"
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Reads the roll's RFID tag and paper info. Missing tags (non-genuine rolls) are not errors.
    @discardableResult
    public func refreshConsumables() async -> Consumables {
        var c = Consumables()
        do {
            let packet = try await request(PacketGenerator.rfidInfo())
            log("RFID raw: \(hex(packet.data))")
            c.rfid = try ResponseParser.rfidInfo(packet)
        } catch {
            log("RFID read failed: \(error.localizedDescription)")
        }
        do {
            c.paper = try ResponseParser.paperInfo(try await request(PacketGenerator.paperInfo()))
            if c.paper == nil { log("Paper info: printer returned no size") }
        } catch {
            log("Paper info not available: \(error.localizedDescription)")
        }
        consumables = c
        onEvent?(.consumablesChanged(c))
        return c
    }

    /// Asks the printer to feed and find the label edge with its gap sensor. Experimental: the meaning of
    /// `value` is undocumented (1 and 2 both feed on B1). Returns the raw response bytes.
    @discardableResult
    public func calibrateLabelPosition(labelType: LabelType, value: UInt8 = 1) async throws -> [UInt8] {
        _ = try? await request(PacketGenerator.setLabelType(labelType))
        let response = try await request(PacketGenerator.labelPositioningCalibration(value), timeout: .seconds(20))
        log("Label calibration response: " + response.data.map { String(format: "%02x", $0) }.joined(separator: " "))
        return response.data
    }

    // MARK: - Settings

    /// Auto shut-down level, 1–4.
    public func autoShutdownLevel() async throws -> Int {
        let response = try await request(PacketGenerator.printerInfo(.autoShutdownTime))
        guard response.data.count == 1 else { throw NiimbotError.malformedPacket("auto shutdown") }
        return Int(response.data[0])
    }

    public func setAutoShutdownLevel(_ level: Int) async throws {
        _ = try await request(PacketGenerator.setAutoShutdownTime(level))
    }

    public func isSoundOn(_ sound: PrinterSound) async throws -> Bool {
        let response = try await request(PacketGenerator.getSound(sound))
        guard response.data.count == 3 else { throw NiimbotError.malformedPacket("sound settings") }
        return response.data[2] != 0
    }

    public func setSound(_ sound: PrinterSound, on: Bool) async throws {
        _ = try await request(PacketGenerator.setSound(sound, on: on))
    }

    // MARK: - Printing

    /// Prints one image `options.copies` times.
    public func print(_ bitmap: MonoBitmap, options: PrintOptions,
                      progress: @escaping (PrintPhase) -> Void = { _ in }) async throws {
        try await print(pages: [bitmap], options: options, progress: progress)
    }

    /// Prints each page in turn, `options.copies` times each, as one print job.
    public func print(pages bitmaps: [MonoBitmap], options: PrintOptions,
                      progress: @escaping (PrintPhase) -> Void = { _ in }) async throws {
        guard let model = info.model else {
            throw NiimbotError.unsupportedModel(info.modelName)
        }
        guard let task = model.printTask(protocolVersion: info.protocolVersion) else {
            throw NiimbotError.unsupportedModel("\(model.name) protocol v\(info.protocolVersion)")
        }
        guard !bitmaps.isEmpty else { return }

        let images = bitmaps.map { ImageEncoder.encode($0, direction: model.direction) }
        let headPixels = info.printheadPixels ?? model.printheadPixels
        if let wide = images.first(where: { $0.cols > headPixels }) {
            throw NiimbotError.unexpectedResponse("image is \(wide.cols)px wide, printhead is \(headPixels)px")
        }

        let copies = max(1, options.copies)
        let total = copies * images.count
        let first = images[0]
        log("Printing \(first.cols)x\(first.rows)px, \(images.count > 1 ? "\(images.count) pages × " : "")\(copies) cop\(copies == 1 ? "y" : "ies") using \(task.rawValue) task")

        isPrinting = true
        defer { isPrinting = false }

        do {
            // Init
            switch task {
            case .d110:
                try await sendAll([PacketGenerator.setDensity(options.density), PacketGenerator.setLabelType(options.labelType),
                                   PacketGenerator.printStart1b()])
            case .b1:
                try await sendAll([PacketGenerator.setDensity(options.density), PacketGenerator.setLabelType(options.labelType),
                                   PacketGenerator.printStart7b(totalPages: total)])
            case .d110mV4:
                try await sendAll([PacketGenerator.setLabelType(options.labelType), PacketGenerator.setDensity(options.density),
                                   PacketGenerator.printStart9b(totalPages: total, speed: options.speed)])
                // The official app sends PrintStatus here without waiting for the reply.
                try await sendOneWay(PacketGenerator.printStatus())
            }

            // Pages
            var packets: [NiimbotPacket] = []
            for image in images {
                let imagePackets = PacketGenerator.imageData(image, printheadPixels: headPixels)
                switch task {
                case .d110:
                    packets += [PacketGenerator.printClear(), PacketGenerator.pageStart(),
                                PacketGenerator.setPageSize4b(rows: image.rows, cols: image.cols),
                                PacketGenerator.setPrintQuantity(copies)] + imagePackets + [PacketGenerator.pageEnd()]
                case .b1:
                    packets += [PacketGenerator.pageStart(),
                                PacketGenerator.setPageSize6b(rows: image.rows, cols: image.cols, copies: copies)]
                        + imagePackets + [PacketGenerator.pageEnd()]
                case .d110mV4:
                    packets += [PacketGenerator.setPageSize13b(rows: image.rows, cols: image.cols, copies: copies)]
                        + imagePackets + [PacketGenerator.pageEnd()]
                }
            }
            try await sendAll(packets, timeout: .seconds(10)) { progress(.sending(percent: $0)) }

            try await waitUntilPrinted(pages: total, progress: progress)
        } catch {
            _ = try? await request(PacketGenerator.printEnd())
            throw error
        }

        let ended = ResponseParser.bool(try await request(PacketGenerator.printEnd()))
        if task == .d110mV4 {
            try? await sendOneWay(PacketGenerator.heartbeat(.advanced1))
        }
        log(ended ? "Print finished" : "Print end not acknowledged")
        await refreshConsumables()
    }

    private func sendAll(_ packets: [NiimbotPacket], timeout: Duration = .seconds(1),
                         progress: ((Int) -> Void)? = nil) async throws {
        var lastPercent = -1
        for (i, packet) in packets.enumerated() {
            try Task.checkCancellation()
            try await send(packet, timeout: timeout)
            let percent = (i + 1) * 100 / packets.count
            if percent / 5 != lastPercent / 5 {
                lastPercent = percent
                progress?(percent)
            }
        }
    }

    private func waitUntilPrinted(pages: Int, progress: (PrintPhase) -> Void) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        var failures = 0
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
            let status: PrintStatus
            do {
                status = try ResponseParser.printStatus(try await request(PacketGenerator.printStatus(), timeout: .seconds(5)))
                failures = 0
            } catch let error as NiimbotError where error != .cancelled && failures < 1 {
                if case .printError = error { throw error }
                failures += 1
                continue
            }
            if status.error != 0 { throw NiimbotError.printError(status.error) }
            progress(.printing(page: status.page, of: pages, percent: status.pagePrintProgress))
            if status.page >= pages { return }
        }
        throw NiimbotError.timeout("waiting for print to finish")
    }

    private func log(_ message: String) {
        onEvent?(.log(message))
    }
}
