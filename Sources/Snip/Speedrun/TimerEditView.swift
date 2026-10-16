import AppKit
import SwiftUI

/// Edits a recording's speedrun timer after the fact: game, category, split names, and when each split
/// happened in the video ("Here" takes the video's current moment). Saving redraws the timer.
struct TimerEditView: View {
    @State private var log: RunLog
    @State private var run = 0
    /// Per run: the clock start, then each split, as editable "m:ss.mmm" text ("" = skipped).
    @State private var times: [[String]]
    @State private var problem: String?

    let now: () -> Double
    let seek: (Double) -> Void
    let onApply: (RunLog) -> Void
    let onCancel: () -> Void

    init(log: RunLog, now: @escaping () -> Double, seek: @escaping (Double) -> Void,
         onApply: @escaping (RunLog) -> Void, onCancel: @escaping () -> Void) {
        _log = State(initialValue: log)
        _times = State(initialValue: log.runs.map { run in
            [VideoTime.format(run.start)] + run.segments.map { $0.split.map(VideoTime.format) ?? "" }
        })
        self.now = now
        self.seek = seek
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Game", text: $log.game)
                TextField("Category", text: $log.category)
                if log.runs.count > 1 {
                    Picker("Run", selection: $run) {
                        ForEach(log.runs.indices, id: \.self) { r in
                            Text("Run \(r + 1) (attempt \(log.runs[r].attempt))").tag(r)
                        }
                    }
                }
            }

            if log.runs.indices.contains(run) {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("Split").foregroundStyle(.secondary)
                            Text("Time in video").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        GridRow {
                            Text("Clock starts").fontWeight(.medium)
                            timeCell(0, placeholder: "0:00.000")
                        }
                        ForEach(log.runs[run].segments.indices, id: \.self) { i in
                            GridRow {
                                TextField("Split name", text: $log.runs[run].segments[i].name)
                                    .frame(minWidth: 140)
                                timeCell(i + 1, placeholder: "skipped")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Text("Play or scrub the video to the moment, then press **Here**. Leave a time empty to skip that split.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save and Redraw") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 360)
    }

    private func timeCell(_ k: Int, placeholder: String) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $times[run][k])
                .font(.body.monospacedDigit())
                .frame(width: 96)
            Button("Here") { times[run][k] = VideoTime.format(now()) }
                .help("Use the moment the video is at now")
            Button {
                if let t = VideoTime.parse(times[run][k]) { seek(t) }
            } label: { Image(systemName: "arrow.right.circle") }
                .buttonStyle(.borderless)
                .help("Show this moment in the video")
                .disabled(VideoTime.parse(times[run][k]) == nil)
            if k > 0 {
                Button { times[run][k] = "" } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Skip this split")
            }
        }
    }

    private func apply() {
        var edited = log
        for r in edited.runs.indices {
            guard let start = VideoTime.parse(times[r][0]) else {
                problem = "Run \(r + 1): the clock start needs a time."
                return
            }
            edited.runs[r].start = start
            for i in edited.runs[r].segments.indices {
                let text = times[r][i + 1].trimmingCharacters(in: .whitespaces)
                if text.isEmpty {
                    edited.runs[r].segments[i].split = nil
                } else if let t = VideoTime.parse(text) {
                    guard t >= start else {
                        problem = "\"\(edited.runs[r].segments[i].name)\" is before the clock starts."
                        return
                    }
                    edited.runs[r].segments[i].split = t
                } else {
                    problem = "\"\(text)\" isn't a time. Use minutes:seconds, like 1:23.450."
                    return
                }
            }
            // The same splits in every run: names follow the run being edited.
            if r != run, edited.runs[r].segments.count == edited.runs[run].segments.count {
                for i in edited.runs[r].segments.indices { edited.runs[r].segments[i].name = edited.runs[run].segments[i].name }
            }
        }
        onApply(edited)
    }
}

/// Video times as people type them: "83.4", "1:23.4" or "1:02:03.5".
enum VideoTime {
    static func format(_ t: Double) -> String {
        let t = max(0, t)
        let minutes = Int(t) / 60
        return String(format: "%d:%06.3f", minutes, t - Double(minutes * 60))
    }

    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
