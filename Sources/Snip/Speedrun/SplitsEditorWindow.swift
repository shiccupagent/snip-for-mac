import AppKit
import SwiftUI

/// LiveSplit's "Edit Splits": game, category, and the list of splits. Saving resets any attempt in
/// progress (as LiveSplit does) and writes the .lss file.
@MainActor
enum SplitsEditorWindow {
    private static var window: NSWindow?

    static func show() {
        window?.close()
        let w = NSWindow(contentViewController: NSHostingController(rootView: SplitsEditorView(
            splits: SpeedrunController.shared.timer.splits,
            close: { window?.close() }
        )))
        w.title = "Edit Splits"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        window = w
        WindowTracker.track(w)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

private struct SplitsEditorView: View {
    @State var splits: Splits
    let close: () -> Void
    @State private var selection: Segment.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Game", text: $splits.game)
                TextField("Category", text: $splits.category)
                LabeledContent("Attempts", value: "\(splits.attempts)")
            }

            Table(splits.segments, selection: $selection) {
                TableColumn("Split name") { segment in
                    TextField("Split name", text: name(segment.id))
                        .textFieldStyle(.plain)
                }
                TableColumn("Personal best") { segment in
                    Text(SpeedrunFormat.time(segment.pbSplit)).monospacedDigit()
                }
                .width(100)
                TableColumn("Best segment") { segment in
                    Text(SpeedrunFormat.time(segment.bestSegment)).monospacedDigit()
                }
                .width(100)
            }
            .frame(minHeight: 260)

            HStack {
                Button { insert(above: false) } label: { Label("Add split", systemImage: "plus") }
                Button { insert(above: true) } label: { Label("Add above", systemImage: "plus.square.on.square") }
                Button { remove() } label: { Label("Remove", systemImage: "minus") }
                    .disabled(selectedIndex == nil || splits.segments.count <= 1)
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .disabled((selectedIndex ?? 0) == 0)
                    .help("Move up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .disabled(selectedIndex.map { $0 >= splits.segments.count - 1 } ?? true)
                    .help("Move down")
                Spacer()
                Button("Clear times…", role: .destructive) { clearTimes() }
                    .help("Forget the personal best and best segments")
            }

            HStack {
                Text("The last split is the finish line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    SpeedrunController.shared.apply(splits)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 520)
    }

    private func name(_ id: Segment.ID) -> Binding<String> {
        Binding(
            get: { splits.segments.first { $0.id == id }?.name ?? "" },
            set: { new in
                if let i = splits.segments.firstIndex(where: { $0.id == id }) { splits.segments[i].name = new }
            }
        )
    }

    private var selectedIndex: Int? {
        selection.flatMap { id in splits.segments.firstIndex { $0.id == id } }
    }

    private func insert(above: Bool) {
        let at = selectedIndex.map { above ? $0 : $0 + 1 } ?? (above ? 0 : splits.segments.count)
        let segment = Segment(name: "")
        splits.segments.insert(segment, at: at)
        // The split after the new one now covers a shorter stretch, so its old gold no longer applies.
        if at + 1 < splits.segments.count { splits.segments[at + 1].bestSegment = nil }
        selection = segment.id
    }

    private func remove() {
        guard let i = selectedIndex, splits.segments.count > 1 else { return }
        // The next split absorbs the removed one, so its gold is the two golds added together.
        if i + 1 < splits.segments.count {
            let a = splits.segments[i].bestSegment, b = splits.segments[i + 1].bestSegment
            splits.segments[i + 1].bestSegment = a.flatMap { a in b.map { a + $0 } }
        }
        splits.segments.remove(at: i)
        selection = splits.segments[min(i, splits.segments.count - 1)].id
    }

    private func move(_ step: Int) {
        guard let i = selectedIndex, splits.segments.indices.contains(i + step) else { return }
        splits.segments.swapAt(i, i + step)
        // Reordering changes what each split measures; its times no longer mean anything.
        for j in [i, i + step] {
            splits.segments[j].pbSplit = nil
            splits.segments[j].bestSegment = nil
        }
    }

    private func clearTimes() {
        let alert = NSAlert()
        alert.messageText = "Clear all times?"
        alert.informativeText = "This forgets the personal best and every best segment for these splits."
        alert.addButton(withTitle: "Clear Times")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for i in splits.segments.indices {
            splits.segments[i].pbSplit = nil
            splits.segments[i].bestSegment = nil
        }
    }
}
