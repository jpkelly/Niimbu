import CoreBluetooth
import Foundation
import NiimbotKit
import Observation

/// App-level printer connection, status and print settings.
@MainActor
@Observable
final class PrinterStore {
    enum Connection: Equatable {
        case disconnected
        case connecting(String)
        case connected(String)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let message: String
    }

    let bluetooth = BluetoothCentral()
    private(set) var connection = Connection.disconnected
    private(set) var info = PrinterInfo()
    private(set) var consumables = Consumables()
    private(set) var heartbeat: HeartbeatData?
    private(set) var printPhase: PrintPhase?
    /// Printer settings, read on connect; nil when the printer didn't answer.
    private(set) var autoShutdownLevel: Int?
    private(set) var sounds: [PrinterSound: Bool] = [:]
    private(set) var isCalibrating = false
    private(set) var log: [LogEntry] = []
    var errorMessage: String?

    // Print settings
    var density = 3
    var copies = 1
    var fastSpeed = false
    /// nil = use what the roll's RFID tag reports.
    var labelTypeOverride: LabelType?
    /// Colours picked for rolls, by RFID barcode.
    private var rollColors: [String: RollColor] = UserDefaults.standard.data(forKey: "rollColors")
        .flatMap { try? JSONDecoder().decode([String: RollColor].self, from: $0) } ?? [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(rollColors), forKey: "rollColors") }
    }
    /// Used when no roll tag has been read.
    var untaggedRollColor = RollColor.white

    /// The loaded roll's colour, remembered per roll.
    var rollColor: RollColor {
        get {
            guard let rfid = consumables.rfid, rfid.tagPresent else { return untaggedRollColor }
            return rollColors[rfid.barCode] ?? .white
        }
        set {
            if let rfid = consumables.rfid, rfid.tagPresent, !rfid.barCode.isEmpty {
                rollColors[rfid.barCode] = newValue
            } else {
                untaggedRollColor = newValue
            }
        }
    }

    var verboseLogging = false {
        didSet { client?.verbose = verboseLogging }
    }

    @ObservationIgnored private var client: NiimbotClient?
    @ObservationIgnored private var printTask: Task<Void, Never>?

    /// The connected model, or the D110 M (the app's main target) before connecting.
    var model: PrinterModel { info.model ?? PrinterModel.find(id: 2320)! }
    var isConnected: Bool { if case .connected = connection { true } else { false } }
    var isPrinting: Bool { printPhase != nil }
    var detectedLabelType: LabelType? { consumables.labelType }
    var labelType: LabelType { labelTypeOverride ?? detectedLabelType ?? .withGaps }

    /// Connect to the last printer whenever it's in range.
    var autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "autoConnect")
            autoConnectIfNeeded()
        }
    }
    /// Set by Disconnect so the printer isn't immediately reconnected; cleared by the next manual connect.
    @ObservationIgnored private var userDisconnected = false

    var lastPrinterID: UUID? {
        get { UserDefaults.standard.string(forKey: "lastPrinterID").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "lastPrinterID") }
    }

    var bluetoothProblem: String? {
        switch bluetooth.state {
        case .unauthorized: "Bluetooth permission was denied. Allow it in System Settings › Privacy & Security."
        case .poweredOff: "Bluetooth is turned off."
        case .unsupported: "This device doesn't support Bluetooth LE."
        default: nil
        }
    }

    /// Connects to the last printer if it has been seen; otherwise scans for it. Call whenever something
    /// changes that might make a connection possible (launch, Bluetooth on, a printer found, a disconnect).
    func autoConnectIfNeeded() {
        guard autoConnect, !userDisconnected, connection == .disconnected, bluetooth.state == .poweredOn,
              let id = lastPrinterID else { return }
        if let found = bluetooth.discovered.first(where: { $0.id == id }) {
            Task { await connect(found, automatic: true) }
        } else if !bluetooth.isScanning {
            bluetooth.startScan()
        }
    }

    /// `automatic` connects stay quiet on failure: the printer may simply be off or in use by another phone.
    func connect(_ printer: DiscoveredPrinter, automatic: Bool = false) async {
        guard !isPrinting, !(automatic && connection != .disconnected) else { return }
        if !automatic { userDisconnected = false }
        disconnect(byUser: false)
        connection = .connecting(printer.name)
        addLog("Connecting to \(printer.name)…")
        do {
            let transport = try await bluetooth.connect(printer)
            let client = NiimbotClient(transport: transport)
            client.verbose = verboseLogging
            client.onEvent = { [weak self, weak client] event in
                // Ignore late events from a client that has since been replaced.
                guard let self, let client, self.client === client else { return }
                self.handle(event)
            }
            self.client = client
            try await client.start()
            info = client.info
            consumables = client.consumables
            density = min(max(density, model.densityRange.lowerBound), model.densityRange.upperBound)
            connection = .connected(printer.name)
            lastPrinterID = printer.id
            await loadSettings()
        } catch {
            client?.disconnect()
            client = nil
            connection = .disconnected
            if automatic {
                addLog("Couldn't reconnect: \(error.localizedDescription)")
                // Try again shortly, by scanning afresh.
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    bluetooth.stopScan()
                    autoConnectIfNeeded()
                }
            } else {
                fail("Couldn't connect: \(error.localizedDescription)")
            }
        }
    }

    func disconnect(byUser: Bool = true) {
        if byUser { userDisconnected = true }
        printTask?.cancel()
        client?.disconnect()
        client = nil
        connection = .disconnected
        heartbeat = nil
        autoShutdownLevel = nil
        sounds = [:]
    }

    private func loadSettings() async {
        guard let client else { return }
        autoShutdownLevel = try? await client.autoShutdownLevel()
        for sound in PrinterSound.allCases {
            sounds[sound] = try? await client.isSoundOn(sound)
        }
    }

    func setAutoShutdownLevel(_ level: Int) {
        guard let client else { return }
        Task {
            do {
                try await client.setAutoShutdownLevel(level)
                autoShutdownLevel = level
            } catch {
                fail("Couldn't change auto shut-down: \(error.localizedDescription)")
            }
        }
    }

    func setSound(_ sound: PrinterSound, on: Bool) {
        guard let client else { return }
        Task {
            do {
                try await client.setSound(sound, on: on)
                sounds[sound] = on
            } catch {
                fail("Couldn't change the sound setting: \(error.localizedDescription)")
            }
        }
    }

    /// Feeds labels until the printer's sensor finds the label edges, so printing lines up. Experimental:
    /// the value sent is a guess (the label type), and the response is logged.
    func calibrate(for type: LabelType) {
        guard let client, !isPrinting, !isCalibrating else { return }
        isCalibrating = true
        addLog("Calibrating for \(type.displayName)…")
        Task {
            defer { isCalibrating = false }
            do {
                try await client.calibrateLabelPosition(labelType: type, value: type.rawValue)
                await refreshConsumables()
            } catch {
                fail("Calibration failed: \(error.localizedDescription)")
            }
        }
    }

    func refreshConsumables() async {
        guard let client else { return }
        consumables = await client.refreshConsumables()
    }

    /// There is no feed command, so this prints one blank label: the printer advances to the next gap.
    func feedLabel(geometry: CanvasGeometry) {
        addLog("Feeding one blank label (\(geometry.width)×\(geometry.height) dots)")
        print(MonoBitmap(width: geometry.width, height: geometry.height), copies: 1)
    }

    func print(_ bitmap: MonoBitmap, copies: Int? = nil) {
        print(pages: [bitmap], copies: copies ?? self.copies)
    }

    /// Prints each page `copies` times in one job. `printed` runs only if the whole job succeeds.
    func print(pages: [MonoBitmap], copies: Int, printed: (() -> Void)? = nil) {
        guard let client, !isPrinting else { return }
        let options = PrintOptions(density: density, labelType: labelType, copies: copies, speed: fastSpeed ? 1 : 0)
        printPhase = .sending(percent: 0)
        printTask = Task {
            do {
                try await client.print(pages: pages, options: options) { [weak self] phase in self?.printPhase = phase }
                printed?()
            } catch is CancellationError {
                addLog("Print cancelled")
            } catch {
                fail("Print failed: \(error.localizedDescription)")
            }
            consumables = client.consumables
            printPhase = nil
        }
    }

    func cancelPrint() {
        printTask?.cancel()
    }

    private func handle(_ event: NiimbotClientEvent) {
        switch event {
        case let .heartbeat(data):
            heartbeat = data
            if let b = data.batteryPercent { info.batteryPercent = b }
        case let .consumablesChanged(c):
            consumables = c
            if let rfid = c.rfid, rfid.tagPresent {
                addLog("Roll: \(rfid.labelType.displayName), \(rfid.remainingLabels.map { "\($0) labels left" } ?? "unknown count") (barcode \(rfid.barCode))")
            } else {
                addLog("Roll: no RFID tag read")
            }
        case let .disconnected(reason):
            client = nil
            connection = .disconnected
            heartbeat = nil
            addLog("Disconnected\(reason.map { ": \($0)" } ?? "")")
            // The printer was turned off or went out of range: reconnect when it's back.
            autoConnectIfNeeded()
        case let .log(message):
            addLog(message)
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        addLog(message)
    }

    private func addLog(_ message: String) {
        log.append(LogEntry(message: message))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
