import NiimbotKit
import SwiftUI

struct InspectorView: View {
    @Environment(LabelDocument.self) private var document
    @Environment(PrinterStore.self) private var printer
    /// Closes the inspector. Shown as a Done button where the inspector is a sheet (iPhone).
    var close: (() -> Void)?

    var body: some View {
        @Bindable var document = document

        Form {
            if let i = document.selectedIndex {
                ElementInspector(element: $document.elements[i])
            }

            Section("Label") {
                Picker("Size", selection: Binding(get: { document.size }, set: setSize)) {
                    ForEach(sizeChoices) { Text($0.name).tag($0) }
                }
                mmField("Width", value: Binding(get: { document.size.width }, set: { setSize(LabelSize(width: $0, height: document.size.height)) }))
                mmField("Height", value: Binding(get: { document.size.height }, set: { setSize(LabelSize(width: document.size.width, height: $0)) }))
                Picker("Colour", selection: Binding(get: { printer.rollColor }, set: { printer.rollColor = $0 })) {
                    ForEach(RollColor.allCases) { color in
                        Label {
                            Text(color.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(color.color)
                        }
                        .tag(color)
                    }
                }
                if let paper = printer.consumables.paper, paper.width > 0 {
                    Text("Roll reports \(paper.width.formatted()) × \(paper.height.formatted()) mm")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let close, UIDevice.current.userInterfaceIdiom == .phone {
                HStack {
                    Text(document.selectedIndex.map { document.elements[$0].kind.title } ?? "Label")
                        .font(.headline)
                    Spacer()
                    Button("Done", action: close)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
        #endif
    }

    /// Picking a size while a roll is loaded teaches the app that roll's size for next time.
    private func setSize(_ size: LabelSize) {
        document.fit(to: size)
        if printer.consumables.paper == nil, let rfid = printer.consumables.rfid, rfid.tagPresent {
            RollSizes.remember(size, for: rfid.barCode)
        }
    }

    /// Presets, plus the current size if it is custom.
    private var sizeChoices: [LabelSize] {
        LabelSize.presets.contains(document.size) ? LabelSize.presets : [document.size] + LabelSize.presets
    }
}

private struct ElementInspector: View {
    @Environment(LabelDocument.self) private var document
    @Binding var element: LabelElement

    var body: some View {
        Section(element.kind.title) {
            switch element.kind {
            case .text:
                // Goes through the document so linked text (cable flag halves) stays in sync.
                TextField("Text", text: Binding(get: { element.text }, set: { document.setText($0, for: element.id) }), axis: .vertical)
                    .lineLimit(1...4)
                Toggle("Fit text to box", isOn: $element.fitToBox)
                // Always visible; changing the size switches off fitting so the change takes effect.
                Stepper(value: Binding(get: { element.fontSize },
                                       set: { element.fontSize = $0; element.fitToBox = false }),
                        in: 4...72) {
                    LabeledContent("Size", value: element.fitToBox ? "Auto" : "\(Int(element.fontSize)) pt")
                }
                FontRow(element: $element)
                Picker("Weight", selection: $element.textWeight) {
                    ForEach(TextWeight.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Italic", isOn: $element.isItalic)
                Picker("Alignment", selection: $element.alignment) {
                    Image(systemName: "text.alignleft").tag(TextAlign.leading)
                    Image(systemName: "text.aligncenter").tag(TextAlign.center)
                    Image(systemName: "text.alignright").tag(TextAlign.trailing)
                }
                .pickerStyle(.segmented)
            case .qrCode, .barcode:
                TextField(element.kind == .qrCode ? "Content" : "Code 128 value", text: $element.text, axis: .vertical)
                    .lineLimit(1...4)
            case .image:
                Toggle("Dither (photos)", isOn: $element.dither)
                LabeledContent("Threshold") {
                    Slider(value: $element.threshold, in: 0.05...0.95)
                }
                Toggle("Invert", isOn: $element.invert)
            case .box, .line:
                Stepper(value: $element.strokeDots, in: 1...16) {
                    LabeledContent("Thickness", value: "\((element.strokeDots / 8).formatted()) mm")
                }
                Toggle("Dashed", isOn: $element.isDashed)
                if element.kind == .box {
                    Stepper(value: $element.radius, in: 0...6, step: 0.5) {
                        LabeledContent("Corner radius", value: "\(element.radius.formatted()) mm")
                    }
                }
            }
        }

        if [.text, .qrCode, .barcode].contains(element.kind) {
            counterSection
        }

        if element.kind != .box && element.kind != .line {
            Section("Rotation") {
                Picker("Rotation", selection: $element.angle) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }

        Section("Position") {
            mmField("X", value: $element.x, positive: false)
            mmField("Y", value: $element.y, positive: false)
            mmField("Width", value: $element.width)
            mmField("Height", value: $element.height)
            HStack {
                Button("Bring to front") { move(toFront: true) }
                Button("Send to back") { move(toFront: false) }
            }
            Button("Delete", role: .destructive) { document.deleteSelected() }
        }
    }

    /// `{#}` in the text becomes a number that goes up by `step` on each label printed.
    @ViewBuilder
    private var counterSection: some View {
        Section {
            if element.hasCounter {
                LabeledContent("Next number") {
                    NumberField("Next number", value: $element.counterSettings.start)
                        .frame(maxWidth: 120)
                }
                Stepper(value: $element.counterSettings.step, in: 1...1000) {
                    LabeledContent("Count by", value: "\(element.counterSettings.step)")
                }
                Stepper(value: $element.counterSettings.digits, in: 1...8) {
                    LabeledContent("Digits", value: element.counterSettings.value(copy: 0))
                }
            } else {
                Button("Insert Number", systemImage: "number") {
                    let text = element.text
                    let joined = text.isEmpty || text.hasSuffix(" ") ? text + Counter.token : text + " " + Counter.token
                    document.setText(joined, for: element.id)
                }
            }
        } header: {
            Text("Number")
        } footer: {
            if element.hasCounter {
                Text("{#} in the text is replaced by the number, which goes up on each label printed.")
            }
        }
    }

    private func move(toFront: Bool) {
        guard let i = document.selectedIndex else { return }
        let e = document.elements.remove(at: i)
        if toFront { document.elements.append(e) } else { document.elements.insert(e, at: 0) }
    }
}

private func mmField(_ title: String, value: Binding<Double>, positive: Bool = true) -> some View {
    LabeledContent(title) {
        NumberField(title, millimetres: value, positive: positive)
            .frame(maxWidth: 80)
        Text("mm").foregroundStyle(.secondary).fixedSize()
    }
}

/// A number field that updates its value on every keystroke. A formatted `TextField` only commits
/// on Return, which the iOS number pads don't have.
private struct NumberField<Value: Equatable>: View {
    let title: String
    @Binding var value: Value
    let decimals: Bool
    let parse: (String) -> Value?
    let format: (Value) -> String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .focused($focused)
            #if os(iOS)
            .keyboardType(decimals ? .decimalPad : .numberPad)
            #endif
            .onAppear { text = format(value) }
            .onChange(of: text) {
                let allowed = text.filter { $0.isNumber || (decimals && ($0 == "." || $0 == ",")) }
                if allowed != text { text = allowed }
                if let v = parse(allowed), v != value { value = v }
            }
            .onChange(of: value) { if parse(text) != value { text = format(value) } }
            .onChange(of: focused) { if !focused { text = format(value) } }
            #if os(iOS)
            .toolbar {
                if focused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focused = false }
                    }
                }
            }
            #endif
    }
}

extension NumberField where Value == Int {
    init(_ title: String, value: Binding<Int>) {
        self.init(title: title, value: value, decimals: false, parse: { Int($0) }, format: { String($0) })
    }
}

extension NumberField where Value == Double {
    /// Millimetres to two decimal places. `positive` rejects zero, for sizes.
    init(_ title: String, millimetres value: Binding<Double>, positive: Bool) {
        self.init(title: title, value: value, decimals: true,
                  parse: { text in
                      // Accept either decimal separator, whatever the locale.
                      guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), !positive || v > 0 else { return nil }
                      return (v * 100).rounded() / 100
                  },
                  format: { $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) })
    }
}

/// Shows the current font; opens a searchable list of system styles and installed families.
private struct FontRow: View {
    @Binding var element: LabelElement
    @State private var choosing = false

    var body: some View {
        Button {
            choosing = true
        } label: {
            LabeledContent("Font") {
                Text(element.fontFamily ?? "System \(element.fontDesign.title)")
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $choosing) {
            FontList(element: $element)
        }
    }
}

private struct FontList: View {
    @Binding var element: LabelElement
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private static let families: [String] = {
        #if os(iOS)
        UIFont.familyNames.sorted()
        #else
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
        #endif
    }()

    private var sample: String {
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Sample" : String(text.prefix(30))
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    Section("System") {
                        ForEach(FontDesign.allCases) { design in
                            row(title: "System \(design.title)", selected: element.fontFamily == nil && element.fontDesign == design,
                                font: .system(size: 22, design: systemDesign(design)).width(design == .condensed ? .condensed : .standard)) {
                                element.fontFamily = nil
                                element.fontDesign = design
                            }
                        }
                    }
                }
                Section("Installed") {
                    ForEach(Self.families.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { family in
                        row(title: family, selected: element.fontFamily == family, font: .custom(family, fixedSize: 22)) {
                            element.fontFamily = family
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search fonts")
            .navigationTitle("Font")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }

    private func row(title: String, selected: Bool, font: Font, choose: @escaping () -> Void) -> some View {
        Button {
            choose()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sample).font(font).lineLimit(1)
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func systemDesign(_ design: FontDesign) -> Font.Design {
        switch design {
        case .standard, .condensed: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}
