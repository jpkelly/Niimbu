import SwiftUI

/// What the loaded roll looks like, for drawing the label in context.
struct LabelStock: Equatable {
    var size: LabelSize
    /// Die-cut labels on a backing liner, with gaps between them. False for continuous tape.
    var hasGaps = true
    /// A wrap-around cable flag, which folds in the middle.
    var isCableFlag = false
    var color = RollColor.white
}

/// Shows the label exactly as it will print (1-bit) on a drawing of the roll, with draggable element frames on top.
struct LabelCanvas: View {
    @Environment(LabelDocument.self) private var document
    let geometry: CanvasGeometry
    let stock: LabelStock
    let preview: CGImage?

    /// The element as it was when the current drag started.
    @State private var dragStart: LabelElement?

    /// Liner shown around the label, in millimetres: enough to see the gap and the next label.
    private var margin: CGSize { stock.hasGaps ? CGSize(width: 5, height: 1.5) : CGSize(width: 4, height: 0) }
    private let gap = 2.0
    /// Cable flags have rounder corners, at the ends and where the two halves meet.
    private var cornerRadius: Double { stock.isCableFlag ? 2.5 : stock.hasGaps ? 1.5 : 0 }

    var body: some View {
        GeometryReader { proxy in
            let dpm = geometry.dotsPerMm
            let zoom = min((proxy.size.width - 16) / CGFloat((stock.size.width + 2 * margin.width) * dpm),
                           (proxy.size.height - 16) / CGFloat((stock.size.height + 2 * margin.height) * dpm), 8)
            let mm = zoom * dpm
            let printable = CGSize(width: CGFloat(geometry.width) * zoom, height: CGFloat(geometry.height) * zoom)
            let label = CGSize(width: stock.size.width * mm, height: stock.size.height * mm)

            ZStack(alignment: .topLeading) {
                roll(label: label, printable: printable, mm: mm)

                ZStack(alignment: .topLeading) {
                    Group {
                        if let preview {
                            // Multiplied over the stock colour: white areas show the label, black prints black.
                            stock.color.color.overlay {
                                Image(decorative: preview, scale: 1)
                                    .resizable()
                                    // Smoothed when magnified: thermal dots bleed into each other on paper,
                                    // so hard pixel steps look far more jagged than the real print.
                                    .interpolation(.medium)
                                    .blendMode(.multiply)
                            }
                            .compositingGroup()
                        } else {
                            stock.color.color
                        }
                    }
                    .frame(width: printable.width, height: printable.height)
                    .mask(alignment: .topLeading) {
                        labelShape(mm: mm).frame(width: label.width, height: label.height)
                    }
                    .onTapGesture { document.selectedID = nil }

                    if stock.isCableFlag {
                        // Fold guide (not printed).
                        Path { p in
                            p.move(to: CGPoint(x: label.width / 2, y: 0))
                            p.addLine(to: CGPoint(x: label.width / 2, y: label.height))
                        }
                        .stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .allowsHitTesting(false)
                    }

                    ForEach(document.elements) { element in
                        overlay(for: element, zoom: zoom)
                    }
                }
                .frame(width: label.width, height: label.height, alignment: .topLeading)
                .offset(x: margin.width * mm, y: margin.height * mm)
            }
            .frame(width: label.width + 2 * margin.width * mm, height: label.height + 2 * margin.height * mm, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 120)
    }

    /// The liner, neighbouring labels, this label's outline and any strip the printhead can't reach.
    private func roll(label: CGSize, printable: CGSize, mm: CGFloat) -> some View {
        let origin = CGPoint(x: margin.width * mm, y: margin.height * mm)
        let shape = labelShape(mm: mm)
        return ZStack(alignment: .topLeading) {
            if stock.hasGaps {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.8))
                // The previous and next labels on the roll.
                ForEach([-1.0, 1.0], id: \.self) { side in
                    shape.fill(stock.color.color.opacity(0.75))
                        .frame(width: label.width, height: label.height)
                        .offset(x: origin.x + side * (label.width + gap * mm), y: origin.y)
                }
            } else {
                // Continuous tape: cut lines where this label will end.
                Rectangle().fill(stock.color.color.opacity(0.75))
                ForEach([0.0, 1.0], id: \.self) { end in
                    Rectangle().fill(Color.gray)
                        .frame(width: 1, height: label.height)
                        .offset(x: origin.x + end * label.width, y: origin.y)
                }
            }
            shape.fill(stock.color.color)
                .frame(width: label.width, height: label.height)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .offset(x: origin.x, y: origin.y)
            if label.height > printable.height + 0.5 {
                // Beyond the printhead.
                Rectangle()
                    .fill(Color.orange.opacity(0.2))
                    .frame(width: label.width, height: label.height - printable.height)
                    .offset(x: origin.x, y: origin.y + printable.height)
                    .mask(alignment: .topLeading) {
                        shape.frame(width: label.width, height: label.height).offset(x: origin.x, y: origin.y)
                    }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func labelShape(mm: CGFloat) -> LabelShape {
        LabelShape(cornerRadius: cornerRadius * mm, split: stock.isCableFlag)
    }

    private func overlay(for element: LabelElement, zoom: CGFloat) -> some View {
        let selected = element.id == document.selectedID
        let scale = zoom * geometry.dotsPerMm
        return Rectangle()
            .strokeBorder(selected ? Color.accentColor : Color.gray.opacity(0.5),
                          style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4, 3]))
            .contentShape(Rectangle())
            .frame(width: max(element.width * scale, 4), height: max(element.height * scale, 4))
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .offset(x: 6, y: 6)
                        .gesture(resizeGesture(element, scale: scale))
                }
            }
            .offset(x: element.x * scale, y: element.y * scale)
            .onTapGesture { document.selectedID = element.id }
            .gesture(moveGesture(element, scale: scale))
            .contextMenu {
                Button(role: .destructive) {
                    document.selectedID = element.id
                    document.deleteSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    private func moveGesture(_ element: LabelElement, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? element
                dragStart = start
                document.selectedID = element.id
                update(element.id) {
                    $0.x = snap(start.x + value.translation.width / scale)
                    $0.y = snap(start.y + value.translation.height / scale)
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ element: LabelElement, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? element
                dragStart = start
                update(element.id) {
                    $0.width = max(1, snap(start.width + value.translation.width / scale))
                    $0.height = max(1, snap(start.height + value.translation.height / scale))
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private func update(_ id: UUID, _ change: (inout LabelElement) -> Void) {
        guard let i = document.elements.firstIndex(where: { $0.id == id }) else { return }
        change(&document.elements[i])
    }

    /// Snaps to a quarter millimetre (2 dots at 203 dpi).
    private func snap(_ mm: Double) -> Double { (mm * 4).rounded() / 4 }
}

/// A die-cut label with rounded corners. Cable flags are two rounded halves whose corners meet at the fold.
struct LabelShape: Shape {
    var cornerRadius: CGFloat
    var split = false

    func path(in rect: CGRect) -> Path {
        let corner = CGSize(width: cornerRadius, height: cornerRadius)
        guard split else { return Path(roundedRect: rect, cornerSize: corner) }
        var p = Path()
        let half = rect.width / 2
        p.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY, width: half, height: rect.height), cornerSize: corner)
        p.addRoundedRect(in: CGRect(x: rect.minX + half, y: rect.minY, width: half, height: rect.height), cornerSize: corner)
        return p
    }
}
