import Foundation

/// An edit to a recording on its timeline: which parts of the video stay, in the original video's
/// seconds. Nothing touches the file until the edit is saved (see `VideoCutter`).
struct TimelineEdit: Equatable {
    let duration: Double
    /// The parts kept, in order, never overlapping.
    private(set) var pieces: [ClosedRange<Double>]

    /// The shortest piece a cut or trim can leave.
    static let minimumPiece = 0.1

    enum Edge { case start, end }

    init(duration: Double) {
        self.duration = max(duration, 0)
        pieces = duration > 0 ? [0...duration] : []
    }

    /// Something was cut out (or trimmed off the ends).
    var isCut: Bool { pieces != (duration > 0 ? [0...duration] : []) }

    var keptDuration: Double { pieces.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    /// The parts that will be cut out.
    var removedParts: [ClosedRange<Double>] {
        var gaps: [ClosedRange<Double>] = []
        var at = 0.0
        for piece in pieces {
            if piece.lowerBound > at { gaps.append(at...piece.lowerBound) }
            at = piece.upperBound
        }
        if at < duration { gaps.append(at...duration) }
        return gaps
    }

    /// The piece under `t`, if `t` is in a kept part.
    func piece(at t: Double) -> Int? {
        pieces.firstIndex { $0.lowerBound <= t && t < $0.upperBound } ?? (pieces.last?.upperBound == t ? pieces.count - 1 : nil)
    }

    /// Cuts the piece under `t` in two, as a video editor's blade does. False if there's nothing to cut there.
    @discardableResult
    mutating func split(at t: Double) -> Bool {
        guard let i = piece(at: t) else { return false }
        let p = pieces[i]
        guard t - p.lowerBound >= Self.minimumPiece, p.upperBound - t >= Self.minimumPiece else { return false }
        pieces.replaceSubrange(i...i, with: [p.lowerBound...t, t...p.upperBound])
        return true
    }

    /// Cuts a piece out. The last piece always stays.
    @discardableResult
    mutating func remove(_ i: Int) -> Bool {
        guard pieces.indices.contains(i), pieces.count > 1 else { return false }
        pieces.remove(at: i)
        return true
    }

    /// Drags one edge of a piece (a trim handle), kept between its neighbours.
    mutating func move(piece i: Int, edge: Edge, to t: Double) {
        guard pieces.indices.contains(i) else { return }
        let p = pieces[i]
        switch edge {
        case .start:
            let low = i > 0 ? pieces[i - 1].upperBound : 0
            pieces[i] = min(max(t, low), p.upperBound - Self.minimumPiece)...p.upperBound
        case .end:
            let high = i + 1 < pieces.count ? pieces[i + 1].lowerBound : duration
            pieces[i] = p.lowerBound...max(min(t, high), p.lowerBound + Self.minimumPiece)
        }
    }

    /// Trims to a moment, like an editor's I and O keys: `.start` drops everything before `t`, `.end`
    /// everything after it. False if that would leave nothing (or only a sliver).
    @discardableResult
    mutating func trim(_ edge: Edge, at t: Double) -> Bool {
        var next = pieces
        switch edge {
        case .start:
            next.removeAll { $0.upperBound <= t }
            if let first = next.first, first.lowerBound < t { next[0] = t...first.upperBound }
        case .end:
            next.removeAll { $0.lowerBound >= t }
            if let last = next.last, last.upperBound > t { next[next.count - 1] = last.lowerBound...t }
        }
        return take(next)
    }

    /// Cuts a stretch of time out, wherever it falls. False if that would leave nothing.
    @discardableResult
    mutating func cut(_ range: ClosedRange<Double>) -> Bool {
        var next: [ClosedRange<Double>] = []
        for p in pieces {
            guard range.lowerBound < p.upperBound, range.upperBound > p.lowerBound else {
                next.append(p)
                continue
            }
            if p.lowerBound < range.lowerBound { next.append(p.lowerBound...range.lowerBound) }
            if range.upperBound < p.upperBound { next.append(range.upperBound...p.upperBound) }
        }
        return take(next.filter { $0.upperBound - $0.lowerBound >= Self.minimumPiece })
    }

    /// Keeps only these stretches (any order; overlaps merge). False if none of them is in the video.
    @discardableResult
    mutating func keep(_ ranges: [ClosedRange<Double>]) -> Bool {
        var next: [ClosedRange<Double>] = []
        let inside = ranges.compactMap { r -> ClosedRange<Double>? in
            let from = max(r.lowerBound, 0), to = min(r.upperBound, duration)
            return from < to ? from...to : nil
        }
        for r in inside.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = next.last, r.lowerBound <= last.upperBound {
                next[next.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                next.append(r)
            }
        }
        return take(next.filter { $0.upperBound - $0.lowerBound >= Self.minimumPiece })
    }

    private mutating func take(_ next: [ClosedRange<Double>]) -> Bool {
        guard !next.isEmpty, next.allSatisfy({ $0.upperBound - $0.lowerBound >= Self.minimumPiece }), next != pieces else { return false }
        pieces = next
        return true
    }

    /// Where `t` in the original video lands in the edited one. A moment that was cut out lands at the cut.
    func editedTime(_ t: Double) -> Double {
        var out = 0.0
        for p in pieces {
            if t < p.lowerBound { return out }
            if t <= p.upperBound { return out + t - p.lowerBound }
            out += p.upperBound - p.lowerBound
        }
        return out
    }

    /// The first kept moment at or after `t` (nil: nothing is kept after it). Playback skips cut parts with this.
    func keptTime(atOrAfter t: Double) -> Double? {
        for p in pieces {
            if t < p.lowerBound { return p.lowerBound }
            if t < p.upperBound { return t }
        }
        return nil
    }

    /// The speedrun log moved onto the edited video's times.
    func apply(to log: RunLog) -> RunLog {
        var out = log
        for r in out.runs.indices {
            let run = log.runs[r]
            out.runs[r].start = editedTime(run.start)
            for s in run.segments.indices {
                out.runs[r].segments[s].split = run.segments[s].split.map(editedTime)
            }
            out.runs[r].pauses = run.pauses.compactMap { pause in
                guard pause.count == 2 else { return nil }
                let from = editedTime(pause[0]), to = editedTime(pause[1])
                return to > from ? [from, to] : nil
            }
            out.runs[r].reset = run.reset.map(editedTime)
        }
        return out
    }

    /// A cut inside a run shortens that run's time on the timer.
    func cutsInsideRun(_ log: RunLog) -> Bool {
        let gaps = removedParts
        return log.runs.contains { run in
            let end = run.reset ?? run.segments.compactMap(\.split).max() ?? duration
            return gaps.contains { $0.lowerBound < end && $0.upperBound > run.start }
        }
    }
}

/// The stretch of the video the timeline shows: all of it, or a zoomed-in part.
struct TimelineViewport: Equatable {
    let duration: Double
    private(set) var start: Double = 0
    private(set) var span: Double

    /// The most zoomed-in view shows half a second across the strip.
    static let minimumSpan = 0.5

    init(duration: Double) {
        self.duration = max(duration, 0)
        span = self.duration
    }

    var end: Double { start + span }
    var zoom: Double { span > 0 ? duration / span : 1 }
    var maxZoom: Double { max(1, duration / Self.minimumSpan) }

    /// Zooms to `zoom` (1 = the whole video), keeping moment `t` at `fraction` (0–1) across the strip.
    mutating func setZoom(_ zoom: Double, keeping t: Double, at fraction: Double) {
        guard duration > 0 else { return }
        span = duration / min(max(zoom, 1), maxZoom)
        start = clampedStart(t - min(max(fraction, 0), 1) * span)
    }

    mutating func pan(by seconds: Double) {
        start = clampedStart(start + seconds)
    }

    /// Brings `t` into view, paging forward as playback reaches the right edge.
    mutating func follow(_ t: Double) {
        guard span < duration, t < start || t > end - span * 0.02 else { return }
        start = clampedStart(t - span * 0.05)
    }

    private func clampedStart(_ s: Double) -> Double {
        min(max(s, 0), max(duration - span, 0))
    }
}
