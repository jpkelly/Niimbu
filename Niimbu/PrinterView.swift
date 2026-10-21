import NiimbotKit
import SwiftUI

/// Find and connect to a printer; shows printer and roll details once connected.
struct PrinterView: View {
    @Environment(PrinterStore.self) private var printer
    @Environment(LabelDocument.self) private var document
    @Environment(\.dismiss) private var dismiss
    @State private var showAllDevices = false

    var body: some View {
        @Bindable var printer = printer

        NavigationStack {
            Form {
                if let problem = printer.bluetoothProblem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }

                if printer.isConnected {
                    connectedSections
                } else {
                    nearbySection
                }

                Section {
                    Picker("Label type", selection: $printer.labelTypeOverride) {
                        Text("Auto (\(printer.detectedLabelType?.displayName ?? "not detected"))").tag(LabelType?.none)
                        ForEach(labelTypeChoices) { type in
                            Text(type.displayName).tag(LabelType?.some(type))
                        }
                    }
                    Toggle("Fast printing", isOn: $printer.fastSpeed)
                } header: {
                    Text("Print settings")
                } footer: {
                    Text("Label type tells the printer how to find the start of each label. Auto uses the roll's tag; choose one only for rolls without a tag.")
                }

                Section("Numbering labels") {
                    Text("""
                        Select a text, QR code or barcode and tap Insert Number in the inspector. It adds {#} to the \
                        text, which prints as a number: 1, 2, 3…

                        Each copy in a print gets the next number, so 5 copies print 1 to 5. After a successful print \
                        the number carries on from where it stopped, so the next print starts at 6. A failed or \
                        cancelled print doesn't use up any numbers.

                        In the inspector you can set the next number, count up in steps (e.g. 10, 20, 30) and pad with \
                        zeros (001, 002…).
                        """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    Toggle("Log every packet", isOn: $printer.verboseLogging)
                    NavigationLink("Log (\(printer.log.count))") { LogView() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Printer")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { if !printer.isConnected { printer.bluetooth.startScan() } }
            .onChange(of: printer.bluetooth.state) { _, state in
                if state == .poweredOn, !printer.isConnected { printer.bluetooth.startScan() }
            }
            .onDisappear {
                printer.bluetooth.stopScan()
                printer.autoConnectIfNeeded()
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var autoConnectToggle: some View {
        Toggle("Connect automatically", isOn: Binding(get: { printer.autoConnect }, set: { printer.autoConnect = $0 }))
    }

    private var nearbySection: some View {
        Section {
            let devices = printer.bluetooth.discovered
                .filter { showAllDevices || $0.looksLikeNiimbot }
                .sorted { ($0.id == printer.lastPrinterID ? 1 : 0, $0.rssi) > ($1.id == printer.lastPrinterID ? 1 : 0, $1.rssi) }
            if devices.isEmpty {
                Text(printer.bluetooth.isScanning ? "Turn the printer on…" : "No printers found")
                    .foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                Button {
                    Task { await printer.connect(device) }
                } label: {
                    HStack {
                        Text(device.name)
                        if device.id == printer.lastPrinterID {
                            Text("Last used").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if case let .connecting(name) = printer.connection, name == device.name {
                            ProgressView().controlSize(.small)
                        } else {
                            HStack(spacing: 3) {
                                BluetoothRune()
                                    .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                    .frame(width: 9, height: 15)
                                Image(systemName: "cellularbars", variableValue: signal(device.rssi))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(printer.connection != .disconnected)
            }
            Toggle("Show all Bluetooth devices", isOn: $showAllDevices)
            autoConnectToggle
        } header: {
            HStack {
                Text("Nearby printers")
                if printer.bluetooth.isScanning { ProgressView().controlSize(.mini) }
            }
        }
    }

    @ViewBuilder
    private var connectedSections: some View {
        let info = printer.info
        Section("Printer") {
            LabeledContent("Model", value: info.modelName)
            if let serial = info.serial { LabeledContent("Serial", value: serial) }
            if let sw = info.softwareVersion {
                LabeledContent("Firmware", value: "\(sw) (hardware \(info.hardwareVersion ?? "?"))")
            }
            LabeledContent("Protocol", value: "v\(info.protocolVersion)")
            if let battery = info.batteryPercent { LabeledContent("Battery", value: "\(battery)%") }
            if let lid = printer.heartbeat?.lidClosed { LabeledContent("Lid", value: lid ? "Closed" : "Open") }
            autoConnectToggle
            Button("Disconnect", role: .destructive) { printer.disconnect() }
        }

        Section("Loaded roll") {
            if let rfid = printer.consumables.rfid, rfid.tagPresent {
                if let name = RollSizes.name(for: rfid.barCode) {
                    LabeledContent("Roll", value: name)
                }
                LabeledContent("Label type", value: rfid.labelType.displayName)
                if let left = rfid.remainingLabels {
                    LabeledContent("Remaining", value: "\(left) of \(rfid.totalLabels)")
                }
                LabeledContent("Barcode", value: rfid.barCode)
                LabeledContent("Roll serial", value: rfid.serialNumber)
            } else {
                Text("No RFID tag read. Non-genuine rolls have no tag; choose the label type manually.")
                    .foregroundStyle(.secondary)
            }
            if let paper = printer.consumables.paper {
                LabeledContent("Size", value: "\(paper.width.formatted()) × \(paper.height.formatted()) mm")
            } else if let rfid = printer.consumables.rfid, rfid.tagPresent, let size = RollSizes.size(for: rfid.barCode) {
                LabeledContent("Size", value: size.name)
            }
            Button("Read again") { Task { await printer.refreshConsumables() } }
            Button("Feed one label") {
                printer.feedLabel(geometry: CanvasGeometry(size: document.size, model: printer.model))
            }
            .disabled(printer.isPrinting)
        }

        Section {
            if let level = printer.autoShutdownLevel {
                Picker("Auto shut-down", selection: Binding(get: { level }, set: { printer.setAutoShutdownLevel($0) })) {
                    Text("15 minutes").tag(1)
                    Text("30 minutes").tag(2)
                    Text("60 minutes").tag(3)
                    Text("Longest").tag(4)
                }
            }
            if let on = printer.sounds[.bluetoothConnection] {
                Toggle("Sound when connecting", isOn: Binding(get: { on }, set: { printer.setSound(.bluetoothConnection, on: $0) }))
            }
            if let on = printer.sounds[.power] {
                Toggle("Sound when turned on", isOn: Binding(get: { on }, set: { printer.setSound(.power, on: $0) }))
            }
        } header: {
            Text("Printer settings")
        } footer: {
            Text("Saved on the printer. Longest may mean never on some models.")
        }

        Section {
            HStack {
                Button("Gap labels") { printer.calibrate(for: .withGaps) }
                Spacer()
                Button("Clear labels") { printer.calibrate(for: .transparent) }
                if printer.isCalibrating { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)
            .disabled(printer.isPrinting || printer.isCalibrating)
        } header: {
            Text("Paper calibration")
        } footer: {
            Text("If printing doesn't line up with the labels, load the roll and calibrate for its type. The printer feeds a few labels to find their edges. Experimental.")
        }
    }

    /// The types this printer takes, plus whatever is detected or chosen so the picker can show it.
    private var labelTypeChoices: [LabelType] {
        let extra = [printer.detectedLabelType, printer.labelTypeOverride].compactMap { $0 }
        return LabelType.allCases.filter { $0 != .invalid && (printer.model.labelTypes.contains($0) || extra.contains($0)) }
    }

    private func signal(_ rssi: Int) -> Double {
        min(1, max(0, Double(rssi + 95) / 45))
    }
}

/// The Bluetooth logo, which SF Symbols doesn't include.
struct BluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0, 0.27))
        path.addLine(to: p(1, 0.73))
        path.addLine(to: p(0.5, 1))
        path.addLine(to: p(0.5, 0))
        path.addLine(to: p(1, 0.27))
        path.addLine(to: p(0, 0.73))
        return path
    }
}

struct LogView: View {
    @Environment(PrinterStore.self) private var printer

    var body: some View {
        List(printer.log.reversed()) { entry in
            VStack(alignment: .leading) {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2).foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ShareLink(item: printer.log.map { "\($0.date.formatted(.iso8601)) \($0.message)" }.joined(separator: "\n"))
        }
    }
}
