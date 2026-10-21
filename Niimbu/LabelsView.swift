import NiimbotKit
import SwiftUI

/// The saved-label library: open, save, rename, duplicate and delete.
struct LabelsView: View {
    @Environment(LabelDocument.self) private var document
    @Environment(PrinterStore.self) private var printer
    @Environment(\.dismiss) private var dismiss

    @State private var namePrompt: NamePrompt?
    /// A label waiting to be opened once the user confirms discarding unsaved changes.
    @State private var pendingOpen: SavedLabel?
    /// Runs once the user confirms discarding unsaved changes.
    @State private var pendingAction: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if document.current == nil {
                            namePrompt = .saveAs(document.suggestedName)
                        } else {
                            document.save()
                        }
                    } label: {
                        Label(document.current.map { "Save “\($0.name)”" } ?? "Save Current Label…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(document.current != nil && !document.hasUnsavedChanges)
                    if document.current != nil {
                        Button {
                            namePrompt = .saveAs(document.suggestedName)
                        } label: {
                            Label("Save as New…", systemImage: "plus.square.on.square")
                        }
                    }
                    Button {
                        confirmUnsaved { startNew() }
                    } label: {
                        Label("New Label", systemImage: "doc.badge.plus")
                    }
                    Button {
                        confirmUnsaved {
                            document.newCableFlag()
                            dismiss()
                        }
                    } label: {
                        Label("New Cable Flag (74 × 12.5 mm)", systemImage: "tag")
                    }
                }

                Section("Saved") {
                    if document.library.isEmpty {
                        Text("No saved labels yet.").foregroundStyle(.secondary)
                    }
                    ForEach(document.library) { label in
                        row(label)
                    }
                }
            }
            .navigationTitle("Labels")
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
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .namePrompt($namePrompt) { prompt, name in
            switch prompt {
            case .saveAs: document.save(name: name)
            case let .rename(id, _): document.rename(id, to: name)
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingOpen != nil }, set: { if !$0 { pendingOpen = nil } })) {
            Button("Discard Changes", role: .destructive) {
                if let pendingOpen { open(pendingOpen) }
            }
        } message: {
            Text("The label you're editing has changes that aren't saved.")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            Button("Discard Changes", role: .destructive) { pendingAction?() }
        } message: {
            Text("The label you're editing has changes that aren't saved.")
        }
    }

    private func row(_ label: SavedLabel) -> some View {
        let geometry = CanvasGeometry(size: label.size, model: printer.model)
        let isCurrent = label.id == document.currentID
        return Button {
            if document.hasUnsavedChanges && !document.elements.isEmpty && !isCurrent {
                pendingOpen = label
            } else {
                open(label)
            }
        } label: {
            HStack(spacing: 12) {
                if let image = LabelRenderer.cgImage(LabelRenderer.render(label.elements, geometry: geometry, cableFlag: label.size == .cableFlag)) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 110, height: 44)
                        .background(Color.white)
                        .border(Color.gray.opacity(0.4))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.name).lineLimit(1)
                    Text("\(label.size.name) · \(label.modified.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…", systemImage: "pencil") { namePrompt = .rename(label.id, label.name) }
            Button("Duplicate", systemImage: "plus.square.on.square") { document.duplicate(label.id) }
            Menu("Change Size", systemImage: "ruler") {
                ForEach(LabelSize.presets) { size in
                    Button { document.changeSize(label.id, to: size) } label: {
                        if size == label.size {
                            Label(size.menuName, systemImage: "checkmark")
                        } else {
                            Text(size.menuName)
                        }
                    }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { document.delete(label.id) }
        }
        #if os(iOS)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { document.delete(label.id) }
            Button("Rename", systemImage: "pencil") { namePrompt = .rename(label.id, label.name) }
        }
        #endif
    }

    private func open(_ label: SavedLabel) {
        document.open(label)
        dismiss()
    }

    private func confirmUnsaved(_ action: @escaping () -> Void) {
        if document.hasUnsavedChanges && !document.elements.isEmpty { pendingAction = action } else { action() }
    }

    private func startNew() {
        document.newLabel()
        dismiss()
    }
}

enum NamePrompt: Identifiable {
    case saveAs(String)
    case rename(UUID, String)

    var id: String {
        switch self {
        case .saveAs: "saveAs"
        case let .rename(id, _): id.uuidString
        }
    }

    var title: String {
        switch self {
        case .saveAs: "Save Label"
        case .rename: "Rename Label"
        }
    }

    var initialName: String {
        switch self {
        case let .saveAs(name), let .rename(_, name): name
        }
    }
}

extension View {
    /// Asks for a label name, then calls `commit` with a non-empty, trimmed name.
    func namePrompt(_ prompt: Binding<NamePrompt?>, commit: @escaping (NamePrompt, String) -> Void) -> some View {
        modifier(NamePromptModifier(prompt: prompt, commit: commit))
    }
}

private struct NamePromptModifier: ViewModifier {
    @Binding var prompt: NamePrompt?
    let commit: (NamePrompt, String) -> Void
    @State private var name = ""
    /// Kept while the alert animates out, after `prompt` is cleared.
    @State private var active: NamePrompt?

    func body(content: Content) -> some View {
        content
            .onChange(of: prompt?.id) {
                if let prompt { active = prompt; name = prompt.initialName }
            }
            .alert(active?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let active, !trimmed.isEmpty { commit(active, trimmed) }
                }
            }
    }
}
