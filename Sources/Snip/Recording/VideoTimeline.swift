import AVFoundation
import SwiftUI

/// The edit on the timeline under a recording: the kept parts of the video and (for speedrun
/// recordings) the run's start and splits as flags. Edits stay here until saved. Changes rarely:
/// only when something is edited, so the strip redraws only then.
@MainActor
final class TimelineModel: ObservableObject {
    @Published private(set) var edit = TimelineEdit(duration: 0)
    /// The speedrun log with any flags moved (nil: not a speedrun recording).
    @Published private(set) var log: RunLog?
    @Published var selected: Int?
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var canUndo = false

    private var savedLog: RunLog?
    private var history: [(TimelineEdit, RunLog?)] = []

    var duration: Double { edit.duration }
    var dirty: Bool { edit.isCut || log != savedLog }

    /// A fresh timeline for the file as it is now.
    func load(duration: Double, log: RunLog?) {
        edit = TimelineEdit(duration: duration)
        self.log = log
        savedLog = log
        selected = nil
        history = []
        canUndo = false
    }

    func setThumbnails(_ images: [CGImage]) { thumbnails = images }

    /// Call before each change (once per drag), so Undo steps back to here.
    func checkpoint() {
        history.append((edit, log))
        if history.count > 200 { history.removeFirst() }
        canUndo = true
    }

    func undo() {
        guard let last = history.popLast() else { return }
        (edit, log) = last
        selected = selected.flatMap { edit.pieces.indices.contains($0) ? $0 : nil }
        canUndo = !history.isEmpty
    }

    func revert() {
        guard dirty else { return }
        checkpoint()
        edit = TimelineEdit(duration: edit.duration)
        log = savedLog
        selected = nil
    }

    /// Applies one change as one Undo step; false (and nothing saved for Undo) if it changed nothing.
    @discardableResult
    func change(_ apply: (inout TimelineEdit) -> Bool) -> Bool {
        var next = edit
        guard apply(&next) else { return false }
        checkpoint()
        edit = next
        return true
    }

    func split(at t: Double) {
        if change({ $0.split(at: t) }) { selected = edit.piece(at: t) }
    }

    /// Cuts out the selected piece (or the one at `t`).
    func removeSelected(or t: Double) {
        guard let i = selected ?? edit.piece(at: t) else { return }
        if change({ $0.remove(i) }) { selected = nil }
    }

    func trim(_ edge: TimelineEdit.Edge, at t: Double) {
        if change({ $0.trim(edge, at: t) }) { selected = nil }
    }

    /// While dragging a handle (after one `checkpoint()` for the whole drag).
    func move(piece i: Int, edge: TimelineEdit.Edge, to t: Double) {
        edit.move(piece: i, edge: edge, to: t)
    }

    // MARK: Speedrun flags

    struct Flag: Identifiable {
        let run: Int
        /// nil: the clock start.
        let segment: Int?
        let time: Double
        let name: String
        var id: String { "\(run)-\(segment ?? -1)" }
    }

    var flags: [Flag] {
        guard let log else { return [] }
        var out: [Flag] = []
        for (r, run) in log.runs.enumerated() {
            out.append(Flag(run: r, segment: nil, time: run.start, name: log.runs.count > 1 ? "Run \(r + 1): clock starts" : "Clock starts"))
            for (s, segment) in run.segments.enumerated() {
                if let split = segment.split { out.append(Flag(run: r, segment: s, time: split, name: segment.name)) }
            }
        }
        return out
    }

    /// Drags a flag: a split can't go before its run's start, and the start can't pass the first split.
    func move(_ flag: Flag, to t: Double) {
        guard var log, log.runs.indices.contains(flag.run) else { return }
        let t = min(max(t, 0), duration)
        if let s = flag.segment {
            guard log.runs[flag.run].segments.indices.contains(s) else { return }
            log.runs[flag.run].segments[s].split = max(t, log.runs[flag.run].start)
        } else {
            let firstSplit = log.runs[flag.run].segments.compactMap(\.split).min() ?? duration
            log.runs[flag.run].start = min(t, firstSplit)
        }
        self.log = log
    }

    /// The line under the timeline: a warning, what's pending, or how to use it.
    var hint: (text: String, warning: Bool) {
        if let log, edit.isCut, edit.cutsInsideRun(log) {
            return ("A cut inside a run makes that run's time shorter on the timer.", true)
        }
        if dirty {
            return ("Not saved yet. Save Edit writes it into the video (the old version goes to the Trash).", false)
        }
        return ("Drag the yellow ends to trim  ·  ⌘B splits at the playhead, Delete cuts the selected piece  ·  I / O trim to the playhead", false)
    }
}

/// The playhead: changes 30 times a second while playing, so only the small views that show it watch it.
@MainActor
final class PlayheadModel: ObservableObject {
    @Published var time: Double = 0
    @Published var playing = false
    @Published var muted = false
    /// Where the pointer is over the strip (nil: not over it).
    @Published var hover: Double?
}

/// The timeline under a recording: a strip of thumbnails with the playhead, yellow trim handles on
/// every kept piece, cut-out parts darkened, speedrun flags above and a time ruler below. Drag
/// anywhere on the strip to scrub.
struct VideoTimelineView: View {
    @ObservedObject var model: TimelineModel
    /// Read for actions only; the views that draw it observe it themselves.
    let playhead: PlayheadModel
    let busy: Bool
    let onSeek: (Double) -> Void
    let onPlayPause: () -> Void
    let onMute: () -> Void
    let onSave: () -> Void

    private let stripHeight: CGFloat = 56
    private let flagRow: CGFloat = 18
    private let rulerHeight: CGFloat = 16
    private let handleWidth: CGFloat = 11
    private let yellow = Color(red: 1, green: 0.8, blue: 0.12)

    /// What a drag in progress is moving (set on its first change, so each drag is one Undo step).
    @State private var dragging: String?
    @State private var draggedFlagName: String?

    var body: some View {
        VStack(spacing: 6) {
            controls
            GeometryReader { g in
                strip(width: max(g.size.width, 1))
            }
            .frame(height: flagRow + stripHeight + rulerHeight)
            Text(model.hint.text)
                .font(.system(size: 11))
                .foregroundStyle(model.hint.warning ? Color.orange : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background(.bar)
        .background(shortcuts)
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }

    // MARK: Buttons and keys

    private var controls: some View {
        HStack(spacing: 4) {
            PlayButton(playhead: playhead, action: onPlayPause)
            TimeReadout(playhead: playhead, edit: model.edit)
                .padding(.leading, 4)
            MuteButton(playhead: playhead, action: onMute)

            Spacer(minLength: 8)

            IconButton(icon: "scissors", help: "Split the clip at the playhead (⌘B)", label: "Split") {
                model.split(at: playhead.time)
            }
            IconButton(icon: "trash", help: "Cut out the selected piece (Delete)", label: "Delete") {
                model.removeSelected(or: playhead.time)
            }
            .disabled(model.edit.pieces.count < 2)
            IconButton(icon: "arrow.uturn.backward", help: "Undo (⌘Z)") { model.undo() }
                .disabled(!model.canUndo)
            IconButton(icon: "arrow.counterclockwise", help: "Revert: back to how the video is saved", label: "Revert") { model.revert() }
                .disabled(!model.dirty)
            Button(action: onSave) { Label("Save Edit", systemImage: "checkmark") }
                .buttonStyle(FilledButtonStyle())
                .disabled(!model.dirty)
                .opacity(model.dirty ? 1 : 0.4)
                .help("Write the edit into the video (the old version goes to the Trash)")
                .padding(.leading, 4)
        }
    }

    /// Keyboard: Space play, ←/→ a frame (⇧ a second), ⌘B split, Delete cut, I/O trim, ⌘Z undo.
    private var shortcuts: some View {
        ZStack {
            Button("") { onPlayPause() }.keyboardShortcut(.space, modifiers: [])
            Button("") { step(-1 / 30) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1 / 30) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [.shift])
            Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [.shift])
            Button("") { model.split(at: playhead.time) }.keyboardShortcut("b")
            Button("") { model.removeSelected(or: playhead.time) }.keyboardShortcut(.delete, modifiers: [])
            Button("") { model.trim(.start, at: playhead.time) }.keyboardShortcut("i", modifiers: [])
            Button("") { model.trim(.end, at: playhead.time) }.keyboardShortcut("o", modifiers: [])
            Button("") { model.undo() }.keyboardShortcut("z")
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func step(_ seconds: Double) {
        let t = min(max(playhead.time + seconds, 0), model.duration)
        playhead.time = t
        onSeek(t)
    }

    // MARK: Strip

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        model.duration > 0 ? CGFloat(t / model.duration) * width : 0
    }

    private func t(_ x: CGFloat, _ width: CGFloat) -> Double {
        min(max(Double(x / width) * model.duration, 0), model.duration)
    }

    private func scrub(to time: Double) {
        playhead.time = time
        onSeek(time)
    }

    private func strip(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Thumbnails. A drag anywhere scrubs; a click also selects the piece there.
            ThumbnailStrip(images: model.thumbnails, height: stripHeight)
                .equatable()
                .frame(width: width, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .offset(y: flagRow)

            // Cut-out parts, darkened.
            ForEach(Array(model.edit.removedParts.enumerated()), id: \.offset) { _, gap in
                let w = max(x(gap.upperBound, width) - x(gap.lowerBound, width), 0)
                Rectangle()
                    .fill(Color.black.opacity(0.66))
                    .overlay(Image(systemName: "scissors").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).opacity(w > 24 ? 1 : 0))
                    .frame(width: w, height: stripHeight)
                    .offset(x: x(gap.lowerBound, width), y: flagRow)
                    .allowsHitTesting(false)
            }

            // The whole strip scrubs (under the handles and flags, which have their own drags).
            Color.clear
                .frame(width: width, height: flagRow + stripHeight + rulerHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { v in scrub(to: t(v.location.x, width)) }
                        .onEnded { v in
                            if abs(v.translation.width) < 3 { model.selected = model.edit.piece(at: t(v.location.x, width)) }
                        }
                )
                .onContinuousHover(coordinateSpace: .named("strip")) { phase in
                    switch phase {
                    case .active(let p): playhead.hover = t(p.x, width)
                    case .ended: playhead.hover = nil
                    }
                }

            // Kept pieces: a yellow frame with a grab handle at each end.
            ForEach(Array(model.edit.pieces.enumerated()), id: \.offset) { i, piece in
                pieceFrame(i, piece, width: width)
            }

            ruler(width: width)
                .offset(y: flagRow + stripHeight + 2)
                .allowsHitTesting(false)

            ForEach(model.flags) { flag in
                flagView(flag, width: width)
            }

            PlayheadLine(playhead: playhead, duration: model.duration, width: width, top: flagRow - 4, height: stripHeight + 8)
                .allowsHitTesting(false)

            if let name = draggedFlagName {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.82)))
                    .foregroundStyle(.white)
                    .offset(x: min(max(x(playhead.time, width) + 6, 0), max(width - 170, 0)), y: flagRow + 5)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: flagRow + stripHeight + rulerHeight, alignment: .topLeading)
        .coordinateSpace(name: "strip")
    }

    /// Time labels under the strip, spaced so they never crowd.
    private func ruler(width: CGFloat) -> some View {
        let duration = model.duration
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { duration > 0 && CGFloat($0 / duration) * width >= 64 } ?? max(duration, 1)
        let marks = duration > 0 ? Array(stride(from: 0, through: duration, by: step)) : []
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { mark in
                VStack(alignment: .leading, spacing: 1) {
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 4)
                    Text(Self.rulerLabel(mark, step: step))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .offset(x: x(mark, width))
            }
        }
        .frame(width: width, height: rulerHeight, alignment: .topLeading)
    }

    static func rulerLabel(_ t: Double, step: Double) -> String {
        let minutes = Int(t) / 60
        let seconds = t - Double(minutes * 60)
        return step < 1 ? String(format: "%d:%04.1f", minutes, seconds) : String(format: "%d:%02d", minutes, Int(seconds))
    }

    private func pieceFrame(_ i: Int, _ piece: ClosedRange<Double>, width: CGFloat) -> some View {
        let left = x(piece.lowerBound, width)
        let right = x(piece.upperBound, width)
        let selected = model.selected == i
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(yellow.opacity(selected ? 0.14 : 0))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(yellow, lineWidth: selected ? 3 : 2))
                .frame(width: max(right - left, 2), height: stripHeight)
                .allowsHitTesting(false)
            handle(i, .start, width: width)
            handle(i, .end, width: width)
                .offset(x: max(right - left - handleWidth, 0))
        }
        .offset(x: left, y: flagRow)
    }

    private func handle(_ i: Int, _ edge: TimelineEdit.Edge, width: CGFloat) -> some View {
        UnevenRoundedRectangle(cornerRadii: edge == .start
                               ? .init(topLeading: 6, bottomLeading: 6, bottomTrailing: 2, topTrailing: 2)
                               : .init(topLeading: 2, bottomLeading: 2, bottomTrailing: 6, topTrailing: 6))
            .fill(yellow)
            .overlay(
                Image(systemName: edge == .start ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.55))
            )
            .frame(width: handleWidth, height: stripHeight)
            .contentShape(Rectangle().inset(by: -5))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("strip"))
                    .onChanged { v in
                        let id = "piece-\(i)-\(edge)"
                        if dragging != id { model.checkpoint(); dragging = id }
                        model.move(piece: i, edge: edge, to: t(v.location.x, width))
                        guard model.edit.pieces.indices.contains(i) else { return }
                        let piece = model.edit.pieces[i]
                        scrub(to: edge == .start ? piece.lowerBound : piece.upperBound)
                    }
                    .onEnded { _ in dragging = nil }
            )
            .help(edge == .start ? "Drag to trim the start" : "Drag to trim the end")
    }

    private func flagView(_ flag: TimelineModel.Flag, width: CGFloat) -> some View {
        let color = flag.segment == nil ? Color(red: 0.1, green: 0.8, blue: 0.3) : SplitColors.currentTop
        return VStack(spacing: 0) {
            Image(systemName: "flag.fill")
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(height: flagRow - 2)
            Rectangle().fill(color).frame(width: 1.5, height: stripHeight + 2)
        }
        .frame(width: 18)
        .contentShape(Rectangle())
        .offset(x: x(flag.time, width) - 4, y: 0)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                .onChanged { v in
                    if dragging != flag.id {
                        if abs(v.translation.width) < 2 { return }
                        model.checkpoint()
                        dragging = flag.id
                    }
                    let time = t(v.location.x, width)
                    model.move(flag, to: time)
                    draggedFlagName = flag.name
                    scrub(to: time)
                }
                .onEnded { _ in
                    // A click without a drag jumps to the flag.
                    if dragging != flag.id { scrub(to: flag.time) }
                    dragging = nil
                    draggedFlagName = nil
                }
        )
        .help("\(flag.name): click to jump there, drag to move the split")
    }
}

// MARK: Small views that follow the playhead (redrawn 30× a second while playing; nothing else is)

private struct PlayheadLine: View {
    @ObservedObject var playhead: PlayheadModel
    let duration: Double
    let width: CGFloat
    let top: CGFloat
    let height: CGFloat

    private func x(_ t: Double) -> CGFloat { duration > 0 ? CGFloat(t / duration) * width : 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Where the pointer is: a faint line and its time, to aim a click.
            if let hover = playhead.hover {
                Rectangle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 1, height: height - 8)
                    .offset(x: x(hover), y: top + 4)
                Text(VideoTime.format(hover))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.75)))
                    .fixedSize()
                    .offset(x: min(max(x(hover) - 30, 0), max(width - 64, 0)), y: max(top - 14, 0))
            }
            // White with a dark outline, so it shows over bright frames and over the yellow handles.
            VStack(spacing: -1) {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(height: 11)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height - 10)
                    .padding(.horizontal, 1)
                    .background(Color.black.opacity(0.7))
            }
            .shadow(color: .black.opacity(0.7), radius: 1)
            .frame(width: 16)
            .offset(x: x(playhead.time) - 8, y: top - 3)
        }
        .frame(width: width, alignment: .topLeading)
    }
}

private struct PlayButton: View {
    @ObservedObject var playhead: PlayheadModel
    let action: () -> Void

    var body: some View {
        IconButton(icon: playhead.playing ? "pause.fill" : "play.fill", help: playhead.playing ? "Pause (Space)" : "Play (Space)", action: action)
    }
}

private struct MuteButton: View {
    @ObservedObject var playhead: PlayheadModel
    let action: () -> Void

    var body: some View {
        IconButton(icon: playhead.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: playhead.muted ? "Unmute" : "Mute", action: action)
    }
}

private struct TimeReadout: View {
    @ObservedObject var playhead: PlayheadModel
    let edit: TimelineEdit

    var body: some View {
        HStack(spacing: 6) {
            Text(VideoTime.format(playhead.time))
                .foregroundStyle(.primary)
            Text("/ \(VideoTime.format(edit.duration))")
                .foregroundStyle(.secondary)
            if edit.isCut {
                Text("→ \(VideoTime.format(edit.keptDuration)) after edit")
                    .foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.1))
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .fixedSize()
    }
}

/// The thumbnails, tiled across the strip. Equatable, so it only redraws when the pictures or size change.
private struct ThumbnailStrip: View, Equatable {
    let images: [CGImage]
    let height: CGFloat

    static func == (a: ThumbnailStrip, b: ThumbnailStrip) -> Bool {
        a.height == b.height && a.images.count == b.images.count && zip(a.images, b.images).allSatisfy { $0 === $1 }
    }

    private var tileWidth: CGFloat {
        guard let first = images.first else { return height * 16 / 9 }
        let aspect = CGFloat(first.width) / CGFloat(max(first.height, 1))
        return max(height * aspect, 24)
    }

    private func tileCount(_ width: CGFloat) -> Int {
        max(Int((width / tileWidth).rounded(.up)), 1)
    }

    /// The picture for tile `k` of `count`: the thumbnail nearest the tile's middle.
    private func image(_ k: Int, of count: Int) -> CGImage {
        let position = (Double(k) + 0.5) / Double(count)
        return images[min(Int(position * Double(images.count)), images.count - 1)]
    }

    var body: some View {
        GeometryReader { g in
            let count = tileCount(g.size.width)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { k in
                    Group {
                        if images.isEmpty {
                            Rectangle().fill(Color.gray.opacity(0.22))
                        } else {
                            Image(decorative: image(k, of: count), scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                    }
                    .frame(width: tileWidth, height: height)
                    .clipped()
                }
            }
            .frame(width: g.size.width, alignment: .leading)
            .clipped()
        }
    }
}
