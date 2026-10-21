import NiimbotKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LabelDocument.self) private var document
    @Environment(PrinterStore.self) private var printer
    @State private var showPrinter = false
    #if os(iOS)
    /// On iPhone the inspector is a sheet over the canvas, so start closed.
    @State private var showInspector = UIDevice.current.userInterfaceIdiom == .pad
    #else
    @State private var showInspector = true
    #endif
    @State private var importingImage = false
    @State private var showLabels = false
    @State private var showAbout = false
    @State private var namePrompt: NamePrompt?
    /// A cable flag roll was just loaded; the printer doesn't line these up itself.
    @State private var offerFlagFeed = false
    /// Barcode of a loaded roll whose size the app doesn't know yet.
    @State private var unknownRoll: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let geometry = CanvasGeometry(size: document.size, model: printer.model)
        let stock = LabelStock(
            size: document.size,
            hasGaps: printer.labelType != .continuous,
            // A cable-flag-sized label is always a flag, whatever roll is loaded; a flag roll makes any label one.
            isCableFlag: document.size == LabelSize.cableFlag
                || printer.consumables.rfid.map { $0.tagPresent && RollSizes.isCableFlag($0.barCode) } == true,
            color: printer.rollColor)
        let bitmap = LabelRenderer.render(document.elements, geometry: geometry, cableFlag: stock.isCableFlag)

        NavigationStack {
            VStack(spacing: 0) {
                StatusBar(showPrinter: $showPrinter)
                if AppBuild.expiresSoon, let left = AppBuild.daysLeftText {
                    Button {
                        showAbout = true
                    } label: {
                        Label("This install stops opening soon: \(left)", systemImage: "clock.badge.exclamationmark")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
                Divider()
                LabelCanvas(geometry: geometry, stock: stock, preview: LabelRenderer.cgImage(bitmap))
                    .padding()
                    .opacity(lidOpen ? 0.35 : 1)
                    .overlay {
                        if lidOpen {
                            Label("Lid open", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.orange, in: Capsule())
                                .allowsHitTesting(false)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: lidOpen)
                if stock.isCableFlag {
                    flagHint
                        .padding(.horizontal)
                }
                printBar(bitmap, geometry: geometry, stock: stock)
                    .padding([.horizontal, .top])
                Group {
                    if document.selectedIndex != nil { selectionBar } else { addBar }
                }
                .padding()
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigation) { labelsMenu }
                #if os(iOS)
                // Name on one line, "Edited" underneath, so long names aren't cut short by the suffix.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(document.current?.name ?? "Untitled").font(.headline).lineLimit(1)
                        if document.current != nil && document.hasUnsavedChanges {
                            Text("Edited").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                #endif
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView(close: { showInspector = false })
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
                    #if os(iOS)
                    .presentationDetents([.fraction(0.45), .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
                    #endif
            }
        }
        .sheet(isPresented: $showPrinter) {
            PrinterView()
        }
        .sheet(isPresented: $showLabels) {
            LabelsView()
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .namePrompt($namePrompt) { _, name in document.save(name: name) }
        .overlay {
            if let phase = printer.printPhase {
                PrintProgressView(phase: phase, copies: printer.copies) { printer.cancelPrint() }
            }
        }
        .alert("Error", isPresented: Binding(get: { printer.errorMessage != nil }, set: { if !$0 { printer.errorMessage = nil } })) {
            Button("OK") { printer.errorMessage = nil }
        } message: {
            Text(printer.errorMessage ?? "")
        }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                document.add(.image, imageData: data)
            }
        }
        .task { printer.autoConnectIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { printer.autoConnectIfNeeded() }
        }
        .onChange(of: printer.bluetooth.state) { printer.autoConnectIfNeeded() }
        .onChange(of: printer.bluetooth.discovered) { printer.autoConnectIfNeeded() }
        .onChange(of: printer.consumables.paper) { _, paper in
            // Printers that report the roll size (paper info) set the canvas automatically.
            if let paper, paper.width > 0, paper.height > 0 {
                document.fit(to: LabelSize(width: paper.width, height: paper.height))
            }
        }
        .onChange(of: printer.consumables.rfid?.barCode) { _, code in
            // Otherwise use the size known (or last printed) for this roll.
            guard printer.consumables.paper == nil, let code, !code.isEmpty else { return }
            if let size = RollSizes.size(for: code) {
                document.fit(to: size)
            } else {
                unknownRoll = code
            }
        }
        .onChange(of: document.currentID) { _, id in
            // A saved label opened with a different roll loaded is fitted to that roll.
            if id != nil, let size = loadedRollSize { document.fit(to: size) }
        }
        .confirmationDialog("What size are these labels?", isPresented: Binding(get: { unknownRoll != nil }, set: { if !$0 { unknownRoll = nil } }), titleVisibility: .visible) {
            if let code = unknownRoll {
                ForEach(LabelSize.presets.filter { $0 != document.size }) { size in
                    Button(size.name) {
                        document.fit(to: size)
                        RollSizes.remember(size, for: code)
                    }
                }
                Button("Keep \(document.size.name)") { RollSizes.remember(document.size, for: code) }
                Button("Not Now", role: .cancel) {}
            }
        } message: {
            Text("The printer doesn't report label size. Your choice is remembered for this roll.")
        }
        .onChange(of: printer.consumables.rfid) { old, new in
            // Only for a roll change seen while connected, not the first read after connecting.
            guard let old, let new, new.tagPresent, RollSizes.isCableFlag(new.barCode),
                  !old.tagPresent || old.serialNumber != new.serialNumber else { return }
            offerFlagFeed = true
        }
        .confirmationDialog("Line up the cable flags?", isPresented: $offerFlagFeed, titleVisibility: .visible) {
            Button("Feed One Label") {
                printer.feedLabel(geometry: CanvasGeometry(size: .cableFlag, model: printer.model))
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("The printer doesn't position cable flag rolls when they're loaded. Feeding one blank label moves the next flag into place (it uses one label).")
        }
        #if os(macOS)
        .onDeleteCommand { document.deleteSelected() }
        .onMoveCommand { direction in
            switch direction {
            case .left: nudge(dx: -1, dy: 0)
            case .right: nudge(dx: 1, dy: 0)
            case .up: nudge(dx: 0, dy: -1)
            case .down: nudge(dx: 0, dy: 1)
            @unknown default: break
            }
        }
        #endif
    }

    /// Content crossing the fold of a cable flag (frames and fold lines are meant to).
    private var acrossFold: [LabelElement] {
        let half = document.size.width / 2
        return document.elements.filter {
            $0.kind != .box && $0.kind != .line && $0.x < half && !LabelRenderer.isLeftHalf($0, labelWidth: document.size.width)
        }
    }

    @ViewBuilder
    private var flagHint: some View {
        if !acrossFold.isEmpty {
            HStack {
                Text("Only content in the left half is repeated on the right.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Fit to Left Half") { fitToLeftHalf() }
                    .font(.caption)
            }
        }
    }

    private func fitToLeftHalf() {
        let half = document.size.width / 2
        for i in document.elements.indices where acrossFold.contains(where: { $0.id == document.elements[i].id }) {
            document.elements[i].x = min(document.elements[i].x, half - 1)
            document.elements[i].width = half - 0.5 - document.elements[i].x
        }
    }

    /// The size of the roll in the printer, when it's known.
    private var loadedRollSize: LabelSize? {
        if let paper = printer.consumables.paper, paper.width > 0, paper.height > 0 {
            return LabelSize(width: paper.width, height: paper.height)
        }
        guard let rfid = printer.consumables.rfid, rfid.tagPresent else { return nil }
        return RollSizes.size(for: rfid.barCode)
    }

    private var lidOpen: Bool { printer.isConnected && printer.heartbeat?.lidClosed == false }

    private var title: String {
        guard let current = document.current else { return "Untitled" }
        return document.hasUnsavedChanges ? "\(current.name) — Edited" : current.name
    }

    /// The saved-label library, saving, and About.
    private var labelsMenu: some View {
        Menu {
            Button("Saved Labels…", systemImage: "folder") { showLabels = true }
                .keyboardShortcut("o")
            Button("Save", systemImage: "square.and.arrow.down") { save() }
                .keyboardShortcut("s")
            Button("Save as New…", systemImage: "plus.square.on.square") { namePrompt = .saveAs(document.suggestedName) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button {
                showAbout = true
            } label: {
                Label("About Niimbu", systemImage: "info.circle")
                if let left = AppBuild.daysLeftText { Text(left) }
            }
        } label: {
            Label("Labels", systemImage: "folder")
        }
    }

    private func save() {
        if document.current == nil { namePrompt = .saveAs(document.suggestedName) } else { document.save() }
    }

    /// The settings that change from print to print.
    private func printBar(_ bitmap: MonoBitmap, geometry: CanvasGeometry, stock: LabelStock) -> some View {
        @Bindable var printer = printer
        return VStack(spacing: 12) {
            HStack {
                Text("\(printer.copies) \(printer.copies == 1 ? "copy" : "copies")").monospacedDigit()
                Stepper("Copies", value: $printer.copies, in: 1...100).labelsHidden()
                Spacer(minLength: 12)
                Text("Density \(printer.density)").monospacedDigit()
                Stepper("Density", value: $printer.density, in: printer.model.densityRange).labelsHidden()
            }
            .font(.subheadline)
            .lineLimit(1)
            printButton(bitmap, geometry: geometry, stock: stock)
        }
    }

    private var addBar: some View {
        HStack {
            ForEach(ElementKind.allCases) { kind in
                Button {
                    if kind == .image { importingImage = true } else { document.add(kind) }
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
        }
        .buttonStyle(.bordered)
        .labelStyle(AdaptiveLabelStyle())
    }

    /// Shown while an element is selected, so editing and deleting don't depend on the inspector.
    private var selectionBar: some View {
        VStack(spacing: 10) {
            nudgeBar
            HStack {
                editButtons
            }
        }
        .buttonStyle(.bordered)
    }

    /// Moves the selection by a quarter millimetre (2 dots) per tap; hold to repeat.
    private var nudgeBar: some View {
        HStack {
            ForEach([("arrow.left", -1.0, 0.0), ("arrow.up", 0, -1), ("arrow.down", 0, 1), ("arrow.right", 1, 0)], id: \.0) { icon, dx, dy in
                Button {
                    nudge(dx: dx, dy: dy)
                } label: {
                    Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 24)
                }
                .buttonRepeatBehavior(.enabled)
                .accessibilityLabel("Nudge \(icon.replacingOccurrences(of: "arrow.", with: ""))")
            }
        }
    }

    private func nudge(dx: Double, dy: Double) {
        guard let i = document.selectedIndex else { return }
        let step = 0.25
        document.elements[i].x = ((document.elements[i].x + dx * step) * 4).rounded() / 4
        document.elements[i].y = ((document.elements[i].y + dy * step) * 4).rounded() / 4
    }

    @ViewBuilder
    private var editButtons: some View {
        Button {
            showInspector = true
        } label: {
            Label("Edit", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 24)
        }
        Button(role: .destructive) {
            document.deleteSelected()
        } label: {
            Label("Delete", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 24)
        }
        .tint(.red)
        Button {
            document.selectedID = nil
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone { showInspector = false }
            #endif
        } label: {
            Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 24)
        }
    }

    private func printButton(_ bitmap: MonoBitmap, geometry: CanvasGeometry, stock: LabelStock) -> some View {
        Button {
            if printer.isConnected {
                if let rfid = printer.consumables.rfid, rfid.tagPresent {
                    RollSizes.remember(document.size, for: rfid.barCode)
                }
                if document.hasCounter {
                    // One page per label so each gets its own number, then carry on from where this run ended.
                    let count = printer.copies
                    let pages = [bitmap] + (1..<max(1, count)).map {
                        LabelRenderer.render(document.elements, geometry: geometry, cableFlag: stock.isCableFlag, copy: $0)
                    }
                    printer.print(pages: pages, copies: 1) { document.advanceCounters(by: count) }
                } else {
                    printer.print(bitmap)
                }
            } else {
                showPrinter = true
            }
        } label: {
            Label("Print", systemImage: "printer")
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("p")
        .disabled(printer.isPrinting)
    }
}

/// Icon-only on compact iPhone widths, icon and title elsewhere.
private struct AdaptiveLabelStyle: LabelStyle {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack { configuration.icon; configuration.title }
        }
    }
}

/// Icon tight against its text, so the bar fits on a phone.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

struct StatusBar: View {
    @Environment(PrinterStore.self) private var printer
    @Binding var showPrinter: Bool

    var body: some View {
        Button {
            showPrinter = true
        } label: {
            HStack(spacing: 10) {
                switch printer.connection {
                case .disconnected:
                    Label("Not connected", systemImage: "printer.dotmatrix")
                        .foregroundStyle(.secondary)
                case let .connecting(name):
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(name)…")
                case .connected:
                    Label(printer.info.modelName, systemImage: "printer.dotmatrix.fill")
                    if let battery = printer.info.batteryPercent {
                        Label("\(battery)%", systemImage: batteryIcon(battery))
                    }
                    if printer.heartbeat?.lidClosed == false {
                        Label("Lid open", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    rollSummary
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .imageScale(.small)
            .labelStyle(StatusLabelStyle())
            .lineLimit(1)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var rollSummary: some View {
        if let rfid = printer.consumables.rfid, rfid.tagPresent {
            Label {
                Text([RollSizes.name(for: rfid.barCode) ?? RollSizes.size(for: rfid.barCode).map(compactSize) ?? "New roll", rfid.remainingLabels.map { "\($0) left" }].compactMap { $0 }.joined(separator: " · "))
            } icon: {
                Image(systemName: "tag")
            }
        } else {
            Label("No roll detected", systemImage: "tag.slash").foregroundStyle(.secondary)
        }
    }

    /// "40×12", without units, to fit the bar.
    private func compactSize(_ size: LabelSize) -> String {
        "\(size.width.formatted())×\(size.height.formatted())"
    }

    private func batteryIcon(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

struct PrintProgressView: View {
    let phase: PrintPhase
    let copies: Int
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch phase {
            case let .sending(percent):
                Text("Sending…")
                ProgressView(value: Double(percent), total: 100)
            case let .printing(page, total, percent):
                Text(total > 1 ? "Printing \(min(page + 1, total)) of \(total)…" : "Printing…")
                ProgressView(value: Double(percent), total: 100)
            }
            Button("Cancel", role: .cancel, action: cancel)
        }
        .frame(width: 240)
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
    }
}
