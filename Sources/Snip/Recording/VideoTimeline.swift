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
    @Published private(set) var canUndo = false
    /// The stretch of video the strip shows (all of it until you zoom in).
    @Published private(set) var viewport = TimelineViewport(duration: 0)
    /// Thumbnails so far, by time. More are made for the stretch in view as you zoom in.
    @Published private(set) var thumbnails: [Thumb] = []
    private(set) var thumbnailVersion = 0

    struct Thumb {
        let time: Double
        let image: CGImage
    }

    private var savedLog: RunLog?
    private var history: [(TimelineEdit, RunLog?)] = []

    var duration: Double { edit.duration }
    var dirty: Bool { edit.isCut || log != savedLog }

    /// A fresh timeline for the file as it is now.
    func load(duration: Double, log: RunLog?) {
        edit = TimelineEdit(duration: duration)
        viewport = TimelineViewport(duration: duration)
        thumbnails = []
        thumbnailVersion += 1
        self.log = log
        savedLog = log
        selected = nil
        history = []
        canUndo = false
    }

    // MARK: Zoom

    /// Zooms by `factor` (above 1 zooms in), keeping moment `t` at `fraction` across the strip.
    func zoom(by factor: Double, keeping t: Double, at fraction: Double) {
        setZoom(viewport.zoom * factor, keeping: t, at: fraction)
    }

    func setZoom(_ zoom: Double, keeping t: Double, at fraction: Double) {
        var next = viewport
        next.setZoom(zoom, keeping: t, at: fraction)
        if next != viewport { viewport = next }
    }

    func pan(by seconds: Double) {
        var next = viewport
        next.pan(by: seconds)
        if next != viewport { viewport = next }
    }

    /// Keeps `t` (the playhead) in view; changes nothing (and redraws nothing) while it already is.
    func follow(_ t: Double) {
        var next = viewport
        next.follow(t)
        if next != viewport { viewport = next }
    }

    // MARK: Thumbnails

    func addThumbnails(_ new: [Thumb]) {
        guard !new.isEmpty else { return }
        var all = (thumbnails + new).sorted { $0.time < $1.time }
        // Keep memory bounded: drop the ones farthest from what's in view.
        if all.count > 600 {
            let middle = viewport.start + viewport.span / 2
            all = Array(all.sorted { abs($0.time - middle) < abs($1.time - middle) }.prefix(600)).sorted { $0.time < $1.time }
        }
        thumbnails = all
        thumbnailVersion += 1
    }

    /// The thumbnail closest to `t`.
    func thumbnail(near t: Double) -> Thumb? {
        Self.nearest(t, in: thumbnails)
    }

    static func nearest(_ t: Double, in thumbs: [Thumb]) -> Thumb? {
        guard !thumbs.isEmpty else { return nil }
        var low = 0, high = thumbs.count - 1
        while low < high {
            let mid = (low + high) / 2
            if thumbs[mid].time < t { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(thumbs[low - 1].time - t) < abs(thumbs[low].time - t) { return thumbs[low - 1] }
        return thumbs[low]
    }

    /// Moments in view whose tile has no thumbnail close enough, for `tiles` tiles across the strip.
    func missingThumbnails(tiles: Int) -> (times: [Double], tolerance: Double) {
        let tileSpan = viewport.span / Double(max(tiles, 1))
        let times = (0..<max(tiles, 1)).map { viewport.start + (Double($0) + 0.5) * tileSpan }.filter { t in
            guard let near = thumbnail(near: t) else { return true }
            return abs(near.time - t) > tileSpan * 0.6
        }
        return (times, tileSpan / 2)
    }

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

    /// Shared with the window, which handles scrolling and pinching over the strip.
    static let sidePadding: CGFloat = 14
    static let stripHeight: CGFloat = 56

    private let stripHeight = Self.stripHeight
    private let flagRow: CGFloat = 18
    private let rulerHeight: CGFloat = 16
    private let overviewHeight: CGFloat = 8
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
            .frame(height: flagRow + stripHeight + rulerHeight + overviewHeight)
            HStack(spacing: 10) {
                Text(model.hint.text)
                    .font(.system(size: 11))
                    .foregroundStyle(model.hint.warning ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                zoomControl
            }
        }
        .padding(.horizontal, Self.sidePadding)
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

    /// − slider + under the strip. The slider is logarithmic, so each bit of it zooms by the same factor.
    private var zoomControl: some View {
        let maxZoom = model.viewport.maxZoom
        return HStack(spacing: 2) {
            IconButton(icon: "minus.magnifyingglass", help: "Zoom out (⌘−)") { zoomStep(1 / 1.6) }
                .disabled(model.viewport.zoom <= 1)
            Slider(value: Binding(
                get: { maxZoom > 1 ? Foundation.log(model.viewport.zoom) / Foundation.log(maxZoom) : 0 },
                set: { setZoom(exp($0 * Foundation.log(maxZoom))) }
            ), in: 0...1)
            .controlSize(.mini)
            .frame(width: 110)
            .help("Zoom the timeline (pinch, or ⌘ + scroll). Scroll sideways to move along it.")
            IconButton(icon: "plus.magnifyingglass", help: "Zoom in (⌘=)") { zoomStep(1.6) }
                .disabled(model.viewport.zoom >= maxZoom)
        }
        .disabled(model.duration <= 0)
    }

    /// Zooms around the playhead when it's in view, otherwise around the middle.
    private func setZoom(_ zoom: Double) {
        let v = model.viewport
        let anchor = (v.start...v.end).contains(playhead.time) ? playhead.time : v.start + v.span / 2
        model.setZoom(zoom, keeping: anchor, at: v.span > 0 ? (anchor - v.start) / v.span : 0.5)
    }

    private func zoomStep(_ factor: Double) { setZoom(model.viewport.zoom * factor) }

    /// Keyboard: Space play, ←/→ a frame (⇧ a second), ⌘B split, Delete cut, I/O trim, ⌘Z undo, ⌘= ⌘− ⌘0 zoom.
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
            Button("") { zoomStep(1.6) }.keyboardShortcut("=")
            Button("") { zoomStep(1 / 1.6) }.keyboardShortcut("-")
            Button("") { setZoom(1) }.keyboardShortcut("0")
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
        let v = model.viewport
        return v.span > 0 ? CGFloat((t - v.start) / v.span) * width : 0
    }

    private func t(_ x: CGFloat, _ width: CGFloat) -> Double {
        let v = model.viewport
        return min(max(v.start + Double(x / width) * v.span, 0), model.duration)
    }

    /// Keeps shapes that run off the strip a sane size when zoomed in (they're clipped anyway).
    private func onStrip(_ x: CGFloat, _ width: CGFloat) -> CGFloat {
        min(max(x, -40), width + 40)
    }

    private func scrub(to time: Double) {
        playhead.time = time
        onSeek(time)
    }

    private func strip(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Thumbnails. A drag anywhere scrubs; a click also selects the piece there.
            ThumbnailStrip(thumbs: model.thumbnails, version: model.thumbnailVersion,
                           start: model.viewport.start, span: model.viewport.span, height: stripHeight)
                .equatable()
                .frame(width: width, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .offset(y: flagRow)

            // Cut-out parts, darkened.
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.edit.removedParts.enumerated()), id: \.offset) { _, gap in
                    let left = onStrip(x(gap.lowerBound, width), width)
                    let w = max(onStrip(x(gap.upperBound, width), width) - left, 0)
                    Rectangle()
                        .fill(Color.black.opacity(0.66))
                        .overlay(Image(systemName: "scissors").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).opacity(w > 24 ? 1 : 0))
                        .frame(width: w, height: stripHeight)
                        .offset(x: left, y: flagRow)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: flagRow + stripHeight, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)

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

            // Kept pieces: a yellow frame with a grab handle at each end (cut off at the strip's ends).
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.edit.pieces.enumerated()), id: \.offset) { i, piece in
                    pieceFrame(i, piece, width: width)
                }
            }
            .frame(width: width, height: flagRow + stripHeight, alignment: .topLeading)
            .clipped()

            ruler(width: width)
                .offset(y: flagRow + stripHeight + 2)
                .allowsHitTesting(false)

            ForEach(model.flags) { flag in
                flagView(flag, width: width)
            }

            overview(width: width)
                .offset(y: flagRow + stripHeight + rulerHeight + 1)

            PlayheadLine(playhead: playhead, start: model.viewport.start, span: model.viewport.span,
                         width: width, top: flagRow - 4, height: stripHeight + 8)
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
        .frame(width: width, height: flagRow + stripHeight + rulerHeight + overviewHeight, alignment: .topLeading)
        // Flags and labels for moments out of view stay hidden; the playhead may still poke into the margin.
        .mask(Rectangle().padding(.horizontal, -Self.sidePadding))
        .coordinateSpace(name: "strip")
    }

    /// When zoomed in: a thin bar showing which part of the video is in view. Drag it to move along.
    @ViewBuilder
    private func overview(width: CGFloat) -> some View {
        let v = model.viewport
        if v.zoom > 1.001, model.duration > 0 {
            let left = CGFloat(v.start / model.duration) * width
            let w = max(CGFloat(v.span / model.duration) * width, 12)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15)).frame(width: width, height: 5)
                Capsule().fill(Color.secondary.opacity(0.55)).frame(width: w, height: 5).offset(x: left)
            }
            .frame(width: width, height: overviewHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let middle = Double(g.location.x / width) * model.duration
                        model.pan(by: middle - (model.viewport.start + model.viewport.span / 2))
                    }
            )
            .help("The part of the video in view. Drag to move along it.")
        }
    }

    /// Time labels under the strip, spaced so they never crowd.
    private func ruler(width: CGFloat) -> some View {
        let v = model.viewport
        let steps: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { v.span > 0 && CGFloat($0 / v.span) * width >= 64 } ?? max(v.span, 1)
        let first = (v.start / step).rounded(.up) * step
        let marks = v.span > 0 ? Array(stride(from: first, through: v.end, by: step)) : []
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
        if step < 0.25 { return String(format: "%d:%05.2f", minutes, seconds) }
        return step < 1 ? String(format: "%d:%04.1f", minutes, seconds) : String(format: "%d:%02d", minutes, Int(seconds.rounded()))
    }

    private func pieceFrame(_ i: Int, _ piece: ClosedRange<Double>, width: CGFloat) -> some View {
        let left = onStrip(x(piece.lowerBound, width), width)
        let right = onStrip(x(piece.upperBound, width), width)
        let selected = model.selected == i
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(yellow.opacity(selected ? 0.14 : 0))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(yellow, lineWidth: selected ? 3 : 2))
                .frame(width: max(right - left, 2), height: stripHeight)
                .allowsHitTesting(false)
            if left > -handleWidth {
                handle(i, .start, width: width)
            }
            if right < width + handleWidth {
                handle(i, .end, width: width)
                    .offset(x: max(right - left - handleWidth, 0))
            }
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
    let start: Double
    let span: Double
    let width: CGFloat
    let top: CGFloat
    let height: CGFloat

    private func x(_ t: Double) -> CGFloat { span > 0 ? CGFloat((t - start) / span) * width : 0 }

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

/// The thumbnails, tiled across the part of the video in view: each tile shows the thumbnail nearest
/// its middle. Equatable, so it only redraws when the pictures or the view change.
private struct ThumbnailStrip: View, Equatable {
    let thumbs: [TimelineModel.Thumb]
    let version: Int
    let start: Double
    let span: Double
    let height: CGFloat

    static func == (a: ThumbnailStrip, b: ThumbnailStrip) -> Bool {
        a.version == b.version && a.start == b.start && a.span == b.span && a.height == b.height
    }

    static func tileWidth(height: CGFloat, aspect: CGFloat?) -> CGFloat {
        max(height * (aspect ?? 16 / 9), 24)
    }

    private var tileWidth: CGFloat {
        Self.tileWidth(height: height, aspect: thumbs.first.map { CGFloat($0.image.width) / CGFloat(max($0.image.height, 1)) })
    }

    private func image(_ k: Int, of count: Int) -> CGImage? {
        let t = start + (Double(k) + 0.5) / Double(count) * span
        return TimelineModel.nearest(t, in: thumbs)?.image
    }

    var body: some View {
        GeometryReader { g in
            let count = max(Int((g.size.width / tileWidth).rounded(.up)), 1)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { k in
                    Group {
                        if let image = image(k, of: count) {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.gray.opacity(0.22))
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

extension TimelineModel {
    /// How many thumbnail tiles fit across a strip `width` points wide.
    func tileCount(width: CGFloat) -> Int {
        let aspect = thumbnails.first.map { CGFloat($0.image.width) / CGFloat(max($0.image.height, 1)) }
        return max(Int((width / ThumbnailStrip.tileWidth(height: VideoTimelineView.stripHeight, aspect: aspect)).rounded(.up)), 1)
    }
}
