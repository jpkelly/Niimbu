import SwiftUI
import Foundation
import Observation

/// Physical label size in millimetres. `width` runs along the feed direction.
struct LabelSize: Codable, Hashable, Identifiable {
    var width: Double
    var height: Double

    var id: String { name }
    var name: String { "\(width.formatted()) × \(height.formatted()) mm" }

    static let cableFlag = LabelSize(width: 74, height: 12.5)

    var menuName: String { self == .cableFlag ? "Cable flag (\(name))" : name }

    /// Common D-series rolls.
    static let presets: [LabelSize] = [
        .init(width: 22, height: 12), .init(width: 26, height: 12), .init(width: 30, height: 12),
        .init(width: 40, height: 12), .init(width: 50, height: 12), .init(width: 75, height: 12),
        .init(width: 30, height: 14), .init(width: 50, height: 14), .init(width: 26, height: 15),
        .init(width: 30, height: 15), .init(width: 40, height: 15), .init(width: 74, height: 12.5), .init(width: 109, height: 12.5),
    ]
}

/// Label sizes by roll barcode. The D110 M reports the roll's RFID barcode but not its size, so
/// sizes come from a few known rolls plus whatever size was last printed on each roll.
enum RollSizes {
    /// Rolls identified by barcode. The RFID label type only says how labels are separated (gaps, black mark…).
    private static let rolls: [String: (name: String, size: LabelSize)] = [
        "6977031211931": ("Cable flag", LabelSize(width: 74, height: 12.5)),
    ]
    private static var known: [String: LabelSize] { rolls.mapValues(\.size) }
    private static let key = "rollSizes"

    /// Known rolls always win, so a size picked by mistake can't stick to them.
    static func size(for barcode: String) -> LabelSize? { known[barcode] ?? learned[barcode] }
    static func name(for barcode: String) -> String? { rolls[barcode]?.name }
    static func isCableFlag(_ barcode: String?) -> Bool { barcode.flatMap(name(for:)) == "Cable flag" }

    static func remember(_ size: LabelSize, for barcode: String) {
        guard !barcode.isEmpty, known[barcode] == nil else { return }
        var sizes = learned
        sizes[barcode] = size
        UserDefaults.standard.set(try? JSONEncoder().encode(sizes), forKey: key)
    }

    private static var learned: [String: LabelSize] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: LabelSize].self, from: $0) } ?? [:]
    }
}

/// The colour of the label stock, for drawing it on the canvas. Printing is always black.
enum RollColor: String, Codable, CaseIterable, Identifiable {
    case white, clear, yellow, orange, pink, red, green, lightBlue, blue, black
    var id: String { rawValue }
    var title: String { self == .lightBlue ? "Light blue" : rawValue.capitalized }

    var color: Color {
        switch self {
        case .white: Color.white
        case .clear: Color(red: 0.93, green: 0.95, blue: 0.97)
        case .yellow: Color(red: 1, green: 0.9, blue: 0.4)
        case .orange: Color(red: 1, green: 0.72, blue: 0.4)
        case .pink: Color(red: 1, green: 0.75, blue: 0.82)
        case .red: Color(red: 0.95, green: 0.45, blue: 0.42)
        case .green: Color(red: 0.6, green: 0.86, blue: 0.6)
        case .lightBlue: Color(red: 0.55, green: 0.76, blue: 0.97)
        case .blue: Color(red: 0.2, green: 0.45, blue: 0.82)
        case .black: Color(white: 0.25)
        }
    }
}

enum ElementKind: String, Codable, CaseIterable, Identifiable {
    case text, qrCode, barcode, image, box, line
    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .qrCode: "QR Code"
        case .barcode: "Barcode"
        case .image: "Image"
        case .box: "Box"
        case .line: "Line"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "textformat"
        case .qrCode: "qrcode"
        case .barcode: "barcode"
        case .image: "photo"
        case .box: "rectangle"
        case .line: "line.diagonal"
        }
    }
}

enum TextWeight: String, Codable, CaseIterable, Identifiable {
    case regular, medium, semibold, bold, heavy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum FontDesign: String, Codable, CaseIterable, Identifiable {
    case standard, rounded, serif, monospaced, condensed
    var id: String { rawValue }
    var title: String { self == .standard ? "Default" : rawValue.capitalized }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
}

/// One item on the label. Position and size are in millimetres from the top-left corner.
struct LabelElement: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: ElementKind
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Text content, or the QR/barcode payload.
    var text = ""
    /// Text: points (1/72 in). Ignored when `fitToBox`.
    var fontSize: Double = 12
    var fitToBox = true
    /// Older saved labels only have `bold`; `weight` is optional so they still decode.
    var bold = false
    var weight: TextWeight?
    var alignment: TextAlign = .center
    /// Optional so labels saved before these existed still decode.
    var design: FontDesign?
    /// An installed font family. When set it replaces the system font and `design`.
    var fontFamily: String?
    var italic: Bool?

    var imageData: Data?
    /// Image: Floyd–Steinberg dithering instead of a hard threshold. Better for photos.
    var dither = false
    /// Image: 0…1, darker pixels than this print.
    var threshold = 0.5
    var invert = false

    /// Clockwise quarter turns in degrees: 0, 90, 180 or 270.
    var rotation: Int?
    /// Box/line stroke thickness in printer dots (8 per mm).
    var lineWidth: Double?
    var dashed: Bool?
    /// Box corner radius in millimetres.
    var cornerRadius: Double?
    /// Text elements sharing a link ID always have the same text (e.g. both halves of a cable flag).
    var linkID: UUID?
    /// Settings for the `{#}` number in the text. Nil means the defaults (start 1, step 1).
    var counter: Counter?

    var angle: Int {
        get { rotation ?? 0 }
        set { rotation = newValue }
    }

    var strokeDots: Double {
        get { lineWidth ?? 2 }
        set { lineWidth = newValue }
    }

    var isDashed: Bool {
        get { dashed ?? false }
        set { dashed = newValue }
    }

    var radius: Double {
        get { cornerRadius ?? 0 }
        set { cornerRadius = newValue }
    }

    var textWeight: TextWeight {
        get { weight ?? (bold ? .bold : .regular) }
        set { weight = newValue }
    }

    var fontDesign: FontDesign {
        get { design ?? .standard }
        set { design = newValue }
    }

    var isItalic: Bool {
        get { italic ?? false }
        set { italic = newValue }
    }

    var hasCounter: Bool { text.contains(Counter.token) }

    var counterSettings: Counter {
        get { counter ?? Counter() }
        set { counter = newValue }
    }

    /// The text with `{#}` replaced by the number for the given copy (0 is the first label printed).
    func resolvedText(copy: Int) -> String {
        hasCounter ? text.replacingOccurrences(of: Counter.token, with: counterSettings.value(copy: copy)) : text
    }
}

/// An incrementing number shown wherever the text contains `{#}`.
struct Counter: Codable, Equatable {
    static let token = "{#}"

    var start = 1
    var step = 1
    /// Minimum digits; shorter numbers are padded with zeros.
    var digits = 1

    func value(copy: Int) -> String {
        let n = start + copy * step
        let s = String(abs(n))
        return (n < 0 ? "-" : "") + String(repeating: "0", count: max(0, digits - s.count)) + s
    }
}

/// A label kept in the library.
struct SavedLabel: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var size: LabelSize
    var elements: [LabelElement]
    var modified = Date()
}

@MainActor
@Observable
final class LabelDocument {
    var size: LabelSize { didSet { save() } }
    var elements: [LabelElement] { didSet { save() } }
    var selectedID: UUID?
    /// The library entry being edited, if the label has been saved.
    private(set) var currentID: UUID? { didSet { save() } }
    /// Saved labels, most recently changed first.
    private(set) var library: [SavedLabel] = [] { didSet { saveLibrary() } }

    var selectedIndex: Int? { elements.firstIndex { $0.id == selectedID } }
    var current: SavedLabel? { library.first { $0.id == currentID } }
    var hasUnsavedChanges: Bool {
        guard let current else { return true }
        return current.size != size || current.elements != elements
    }

    private struct Stored: Codable {
        var size: LabelSize
        var elements: [LabelElement]
        var currentID: UUID?
    }

    private static func fileURL(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private static let workingURL = fileURL("label.json")
    private static let libraryURL = fileURL("library.json")

    init() {
        if let data = try? Data(contentsOf: Self.workingURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            size = stored.size
            elements = stored.elements
            currentID = stored.currentID
        } else {
            size = LabelSize(width: 40, height: 12)
            elements = [LabelElement(kind: .text, x: 1, y: 1, width: 38, height: 10, text: "Hello Niimbu")]
        }
        if let data = try? Data(contentsOf: Self.libraryURL),
           let saved = try? JSONDecoder().decode([SavedLabel].self, from: data) {
            library = saved
        }
    }

    private func save() {
        let data = try? JSONEncoder().encode(Stored(size: size, elements: elements, currentID: currentID))
        try? data?.write(to: Self.workingURL, options: .atomic)
    }

    private func saveLibrary() {
        let data = try? JSONEncoder().encode(library)
        try? data?.write(to: Self.libraryURL, options: .atomic)
    }

    // MARK: - Library

    /// Overwrites the open library entry, or saves a new one when the label has never been saved.
    func save(name: String? = nil) {
        if let i = library.firstIndex(where: { $0.id == currentID }), name == nil {
            library[i].size = size
            library[i].elements = elements
            library[i].modified = .now
            library.sort { $0.modified > $1.modified }
        } else {
            let label = SavedLabel(name: name ?? suggestedName, size: size, elements: elements)
            library.insert(label, at: 0)
            currentID = label.id
        }
    }

    /// The first text on the label, for naming new saves.
    var suggestedName: String {
        let text = elements.first { $0.kind == .text && !$0.text.isEmpty }?.text
        return text.map { String($0.split(separator: "\n").first ?? "").prefix(40) }.map(String.init) ?? "Label"
    }

    func open(_ label: SavedLabel) {
        selectedID = nil
        size = label.size
        elements = label.elements
        currentID = label.id
    }

    /// Starts an empty label at the current size.
    func newLabel() {
        selectedID = nil
        elements = []
        currentID = nil
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = library.firstIndex(where: { $0.id == id }) else { return }
        library[i].name = name
    }

    func duplicate(_ id: UUID) {
        guard var copy = library.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name += " copy"
        copy.modified = .now
        library.insert(copy, at: 0)
    }

    /// Moves a saved label onto a different size of roll, scaling its contents to fit.
    func changeSize(_ id: UUID, to newSize: LabelSize) {
        guard let i = library.firstIndex(where: { $0.id == id }), library[i].size != newSize else { return }
        let wasOpenUnchanged = currentID == id && !hasUnsavedChanges
        let elements = Self.rescaled(library[i].elements, from: library[i].size, to: newSize)
        library[i].size = newSize
        library[i].elements = elements
        library[i].modified = .now
        if wasOpenUnchanged {
            selectedID = nil
            size = newSize
            self.elements = elements
        }
    }

    /// Fits the label being edited to a different roll, scaling its contents. A saved label then shows as
    /// edited until it's saved at the new size.
    func fit(to newSize: LabelSize) {
        guard newSize != size else { return }
        elements = Self.rescaled(elements, from: size, to: newSize)
        size = newSize
    }

    /// Scales label contents from one size to another. Into a cable flag the contents go in the left half
    /// (the printer repeats it on the right); out of one, only the left half is kept and stretched across.
    static func rescaled(_ elements: [LabelElement], from old: LabelSize, to newSize: LabelSize) -> [LabelElement] {
        let fromFlag = old == .cableFlag, toFlag = newSize == .cableFlag
        var source = elements
        var sourceWidth = old.width
        if fromFlag {
            // Drop the full-width frame, the fold line and the mirrored right half.
            let half = old.width / 2
            source = source.filter {
                LabelRenderer.isLeftHalf($0, labelWidth: old.width) && !($0.kind == .line && $0.isDashed && $0.x + $0.width > half - 1.5)
            }
            sourceWidth = half
        }
        let targetWidth = toFlag ? newSize.width / 2 : newSize.width
        let sx = targetWidth / sourceWidth, sy = newSize.height / old.height
        var result = source.map { e in
            var e = e
            e.x *= sx; e.width *= sx
            e.y *= sy; e.height *= sy
            e.fontSize *= min(sx, sy)
            return e
        }
        if toFlag && !fromFlag && !result.isEmpty {
            var fold = LabelElement(kind: .line, x: targetWidth - 0.5, y: 0.5, width: 1, height: newSize.height - 1)
            fold.isDashed = true
            result.append(fold)
        }
        return result
    }

    func delete(_ id: UUID) {
        library.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
    }

    func add(_ kind: ElementKind, imageData: Data? = nil) {
        let h = min(size.height - 2, 10)
        var e = LabelElement(kind: kind, x: 1, y: 1, width: h, height: h)
        switch kind {
        case .text:
            e.width = size.width - 2
            e.text = "Text"
            // Thin strokes break up at 8 dots/mm; a heavier default prints more cleanly.
            e.weight = .semibold
        case .qrCode:
            e.text = "https://example.com"
        case .barcode:
            e.width = min(size.width - 2, 35)
            e.text = "12345678"
        case .image:
            e.imageData = imageData
            e.width = min(size.width - 2, h * 2)
        case .box:
            e = LabelElement(kind: kind, x: 0.5, y: 0.5, width: size.width - 1, height: printableHeight - 1)
        case .line:
            // Vertical: lines run along the longer side of their frame.
            e = LabelElement(kind: kind, x: (size.width / 2 - 0.5).rounded(), y: 0.5, width: 1, height: printableHeight - 1)
        }
        elements.append(e)
        selectedID = e.id
    }

    /// The label height the D-series printhead can reach (96 dots = 12 mm).
    private var printableHeight: Double { min(size.height, 12) }

    /// Sets text on an element and on every element linked to it.
    var hasCounter: Bool { elements.contains(where: \.hasCounter) }

    /// Moves every counter on past the labels just printed, so the next print continues the sequence.
    func advanceCounters(by copies: Int) {
        for i in elements.indices where elements[i].hasCounter {
            elements[i].counterSettings.start += copies * elements[i].counterSettings.step
        }
    }

    func setText(_ text: String, for id: UUID) {
        guard let link = elements.first(where: { $0.id == id })?.linkID else {
            if let i = elements.firstIndex(where: { $0.id == id }) { elements[i].text = text }
            return
        }
        for i in elements.indices where elements[i].linkID == link { elements[i].text = text }
    }

    /// A wrap-around cable flag: a frame, a fold line and text in the left half. The renderer repeats the
    /// left half upside down on the right so both sides read correctly once folded around a cable.
    func newCableFlag(text: String = "CABLE", size: LabelSize = .cableFlag) {
        let h = min(size.height, 12)
        let half = size.width / 2
        var left = LabelElement(kind: .text, x: 1.5, y: 1.5, width: half - 2.5, height: h - 3, text: text)
        left.weight = .semibold
        var frame = LabelElement(kind: .box, x: 0.5, y: 0.5, width: size.width - 1, height: h - 1)
        frame.radius = 1
        var fold = LabelElement(kind: .line, x: half - 0.5, y: 0.5, width: 1, height: h - 1)
        fold.isDashed = true

        selectedID = nil
        self.size = size
        elements = [frame, fold, left]
        currentID = nil
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        elements.remove(at: i)
        selectedID = nil
    }
}
