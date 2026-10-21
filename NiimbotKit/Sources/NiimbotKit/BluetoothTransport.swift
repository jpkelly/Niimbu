import CoreBluetooth
import Foundation
import Observation

public struct DiscoveredPrinter: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public var rssi: Int
    let peripheral: CBPeripheral

    /// NIIMBOT printers advertise as model + serial, e.g. "D110_M-H322062548".
    public var looksLikeNiimbot: Bool {
        name.range(of: #"^[A-Z]{1,2}\d"#, options: .regularExpression) != nil
    }
}

/// Scans for and connects to printers over Bluetooth LE.
@MainActor
@Observable
public final class BluetoothCentral: NSObject {
    public private(set) var state: CBManagerState = .unknown
    public private(set) var isScanning = false
    public private(set) var discovered: [DiscoveredPrinter] = []

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var pendingConnect: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    @ObservationIgnored private var transports: [UUID: BluetoothTransport] = [:]

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func startScan() {
        guard state == .poweredOn else { return }
        discovered.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }

    public func stopScan() {
        central.stopScan()
        isScanning = false
    }

    /// Connects and finds the printer's notify + write-without-response characteristic.
    public func connect(_ printer: DiscoveredPrinter, timeout: Duration = .seconds(10)) async throws -> BluetoothTransport {
        stopScan()
        let peripheral = printer.peripheral
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let pending = self.pendingConnect, pending.id == printer.id else { return }
            self.pendingConnect = nil
            self.central.cancelPeripheralConnection(peripheral)
            pending.continuation.resume(throwing: NiimbotError.timeout("Bluetooth connect"))
        }
        defer { timer.cancel() }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pendingConnect = (printer.id, c)
            central.connect(peripheral)
        }

        let transport = BluetoothTransport(peripheral: peripheral) { [weak self] in
            self?.central.cancelPeripheralConnection(peripheral)
        }
        transports[printer.id] = transport
        do {
            try await transport.setUp()
        } catch {
            transports[printer.id] = nil
            central.cancelPeripheralConnection(peripheral)
            throw error
        }
        return transport
    }
}

extension BluetoothCentral: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            state = central.state
            if central.state != .poweredOn { isScanning = false }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        MainActor.assumeIsolated {
            guard let name, !name.isEmpty else { return }
            let printer = DiscoveredPrinter(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral)
            if let i = discovered.firstIndex(where: { $0.id == printer.id }) {
                discovered[i].rssi = printer.rssi
            } else {
                discovered.append(printer)
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard let pending = pendingConnect, pending.id == peripheral.identifier else { return }
            pendingConnect = nil
            pending.continuation.resume()
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard let pending = pendingConnect, pending.id == peripheral.identifier else { return }
            pendingConnect = nil
            pending.continuation.resume(throwing: NiimbotError.bluetooth(error?.localizedDescription ?? "failed to connect"))
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            transports.removeValue(forKey: peripheral.identifier)?.didDisconnect(error)
        }
    }
}

/// A connected printer. Writes are chunked to the BLE MTU and flow-controlled.
@MainActor
public final class BluetoothTransport: NSObject, NiimbotTransport {
    public var onReceive: ((Data) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let peripheral: CBPeripheral
    private let cancelConnection: () -> Void
    private var characteristic: CBCharacteristic?
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var pendingServices = 0

    init(peripheral: CBPeripheral, cancelConnection: @escaping () -> Void) {
        self.peripheral = peripheral
        self.cancelConnection = cancelConnection
        super.init()
        peripheral.delegate = self
    }

    func setUp() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            setupContinuation = c
            peripheral.discoverServices(nil)
        }
    }

    private func finishSetUp(_ result: Result<Void, Error>) {
        setupContinuation?.resume(with: result)
        setupContinuation = nil
    }

    public func write(_ data: Data) async throws {
        guard let characteristic, peripheral.state == .connected else { throw NiimbotError.notConnected }
        let mtu = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < data.count {
            while !peripheral.canSendWriteWithoutResponse {
                await withCheckedContinuation { readyContinuation = $0 }
                guard peripheral.state == .connected else { throw NiimbotError.notConnected }
            }
            let chunk = data.subdata(in: offset..<min(offset + mtu, data.count))
            peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            offset += chunk.count
        }
    }

    public func close() {
        cancelConnection()
    }

    fileprivate func didDisconnect(_ error: Error?) {
        characteristic = nil
        readyContinuation?.resume()
        readyContinuation = nil
        finishSetUp(.failure(NiimbotError.notConnected))
        onDisconnect?(error)
    }
}

extension BluetoothTransport: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            // Skip standard 16-bit services (GAP, GATT, battery…); the printer channel is a 128-bit UUID.
            let services = (peripheral.services ?? []).filter { $0.uuid.uuidString.count > 4 }
            guard error == nil, !services.isEmpty else {
                finishSetUp(.failure(NiimbotError.bluetooth(error?.localizedDescription ?? "no printer service found")))
                return
            }
            pendingServices = services.count
            services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            pendingServices -= 1
            if characteristic == nil,
               let c = service.characteristics?.first(where: { $0.properties.contains(.notify) && $0.properties.contains(.writeWithoutResponse) }) {
                characteristic = c
                peripheral.setNotifyValue(true, for: c)
            } else if pendingServices == 0 && characteristic == nil {
                finishSetUp(.failure(NiimbotError.bluetooth("no suitable characteristic found")))
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                finishSetUp(.failure(NiimbotError.bluetooth(error.localizedDescription)))
            } else {
                finishSetUp(.success(()))
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        MainActor.assumeIsolated {
            if let value, !value.isEmpty { onReceive?(value) }
        }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }
}
