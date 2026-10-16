import Foundation

/// The speedrun clock and its splits, with LiveSplit's controls and rules: Split (also starts and
/// resumes), Undo, Skip, Pause and Reset. Personal bests and golds are saved when a run is reset.
/// A name on the timer that can be edited in place.
enum SplitsField: Hashable {
    case game, category, segment(Int)
}

@MainActor
final class SpeedrunTimer: ObservableObject {
    enum Phase { case idle, running, paused, ended }

    /// How a time compares with the personal best, coloured as LiveSplit does.
    enum Standing { case aheadGaining, aheadLosing, behindGaining, behindLosing, gold, personalBest, neutral }

    @Published private(set) var phase: Phase = .idle
    /// The split being run now (equals the segment count once the run has ended).
    @Published private(set) var index = 0
    /// This attempt's clock time at each split; nil until split (or when skipped).
    @Published private(set) var times: [TimeInterval?] = []
    @Published private(set) var splits: Splits

    /// What the runner did, as it takes effect. Recordings log these so a run can be re-timed later.
    enum Event: Equatable {
        case start
        case split(Int)   // finished segment i
        case undo(Int)    // reopened segment i
        case skip(Int)
        case pause, resume, reset
    }

    /// Called whenever the splits change and should be saved.
    var onSplitsChanged: ((Splits) -> Void)?
    var onEvent: ((Event) -> Void)?

    /// Seconds on a steady clock. Live timers use the system's; a replay uses the video's time.
    private let clock: () -> TimeInterval
    private var startedAt: TimeInterval?
    private var pausedAt: TimeInterval?
    private var pausedFor: TimeInterval = 0
    private var endedAt: TimeInterval?

    init(splits: Splits, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.splits = splits
        self.clock = clock
    }

    var segmentCount: Int { splits.segments.count }

    /// The time on the clock right now.
    var now: TimeInterval {
        if let endedAt { return endedAt }
        guard let startedAt else { return splits.offset }
        return splits.offset + (pausedAt ?? clock()) - startedAt - pausedFor
    }

    // MARK: Controls

    func split() {
        switch phase {
        case .idle:
            start()
        case .paused:
            togglePause()
        case .running:
            let t = now
            guard t >= 0, index < segmentCount else { return } // still counting down the offset
            times[index] = t
            index += 1
            onEvent?(.split(index - 1))
            if index == segmentCount {
                endedAt = t
                phase = .ended
            }
        case .ended:
            break
        }
    }

    func undo() {
        switch phase {
        case .ended:
            endedAt = nil
            index = segmentCount - 1
            times[index] = nil
            phase = .running
            onEvent?(.undo(index))
        case .running, .paused:
            guard index > 0 else { return }
            index -= 1
            times[index] = nil
            onEvent?(.undo(index))
        case .idle:
            break
        }
    }

    func skip() {
        guard phase == .running || phase == .paused, index < segmentCount - 1 else { return }
        times[index] = nil
        index += 1
        onEvent?(.skip(index - 1))
    }

    func togglePause() {
        switch phase {
        case .running:
            pausedAt = clock()
            phase = .paused
            onEvent?(.pause)
        case .paused:
            if let pausedAt { pausedFor += clock() - pausedAt }
            pausedAt = nil
            phase = .running
            onEvent?(.resume)
        case .idle, .ended:
            break
        }
    }

    /// Ends the attempt, keeping any new golds and, for a finished run that beat it, the new PB.
    func reset() {
        guard phase != .idle else { return }
        var updated = splits
        var previous: TimeInterval? = 0
        for i in 0..<segmentCount {
            guard let t = times[i] else { previous = nil; continue }
            if let previous, t - previous > 0, t - previous < (updated.segments[i].bestSegment ?? .infinity) {
                updated.segments[i].bestSegment = t - previous
            }
            previous = t
        }
        if phase == .ended, let final = times.last ?? nil, final < (splits.pbTime ?? .infinity) {
            for i in 0..<segmentCount { updated.segments[i].pbSplit = times[i] }
        }
        clear()
        onEvent?(.reset)
        replaceSplits(updated)
    }

    /// Renames the game, the category or one split. Unlike replacing the splits, the attempt keeps going.
    func rename(_ field: SplitsField, to name: String) {
        switch field {
        case .game: splits.game = name
        case .category: splits.category = name
        case .segment(let i):
            guard splits.segments.indices.contains(i) else { return }
            splits.segments[i].name = name
        }
        onSplitsChanged?(splits)
    }

    /// New splits from the editor or a file. Any attempt in progress is reset first.
    func replaceSplits(_ new: Splits) {
        if phase != .idle { reset() }
        splits = new
        onSplitsChanged?(new)
    }

    private func start() {
        guard segmentCount > 0 else { return }
        clear()
        times = Array(repeating: nil, count: segmentCount)
        startedAt = clock()
        splits.attempts += 1
        onSplitsChanged?(splits)
        phase = .running
        onEvent?(.start)
    }

    private func clear() {
        phase = .idle
        index = 0
        times = []
        startedAt = nil
        pausedAt = nil
        pausedFor = 0
        endedAt = nil
    }

    // MARK: What the display shows

    /// Ahead (negative) or behind (positive) the PB at split `i` of this attempt.
    func delta(_ i: Int) -> TimeInterval? {
        guard i < times.count, let t = times[i], let pb = splits.segments[i].pbSplit else { return nil }
        return t - pb
    }

    /// The running delta for the current split, shown once the PB's time for it has passed.
    var liveDelta: TimeInterval? {
        guard phase == .running || phase == .paused, index < segmentCount,
              let pb = splits.segments[index].pbSplit, now > pb else { return nil }
        return now - pb
    }

    /// This attempt's length of segment `i`, when both of its splits were hit.
    func segmentTime(_ i: Int) -> TimeInterval? {
        guard i < times.count, let end = times[i] else { return nil }
        if i == 0 { return end }
        return times[i - 1].map { end - $0 }
    }

    func standing(_ i: Int) -> Standing {
        guard let delta = delta(i) else { return .neutral }
        if let seg = segmentTime(i), seg < (splits.segments[i].bestSegment ?? .infinity) { return .gold }
        let gaining = segmentTime(i).flatMap { seg in splits.pbSegment(i).map { seg < $0 } } ?? (delta < 0)
        if delta < 0 { return gaining ? .aheadGaining : .aheadLosing }
        return gaining ? .behindGaining : .behindLosing
    }

    /// Colour of the big timer.
    var timerStanding: Standing {
        switch phase {
        case .idle, .paused:
            return .neutral
        case .ended:
            guard let final = endedAt else { return .neutral }
            return final < (splits.pbTime ?? .infinity) ? .personalBest : .behindLosing
        case .running:
            if let live = liveDelta { return live > 0 ? .behindLosing : .aheadGaining }
            let last = (0..<index).reversed().first { delta($0) != nil }
            guard let last else { return splits.pbTime == nil ? .neutral : .aheadGaining }
            return standing(last) == .gold ? (delta(last)! < 0 ? .aheadGaining : .behindLosing) : standing(last)
        }
    }

    /// Time saved (negative) or lost on the last finished segment against the PB's same segment.
    var previousSegment: (delta: TimeInterval, standing: Standing)? {
        let last = (0..<min(index, segmentCount)).reversed().first { times[$0] != nil }
        guard let last, let seg = segmentTime(last), let pbSeg = splits.pbSegment(last) else { return nil }
        let gold = seg < (splits.segments[last].bestSegment ?? .infinity)
        return (seg - pbSeg, gold ? .gold : (seg < pbSeg ? .aheadGaining : .behindLosing))
    }
}

/// LiveSplit's number styles: the timer "1:23.45", splits "1:23.45", deltas "+1.2" / "−0.4".
enum SpeedrunFormat {
    static func clock(_ t: TimeInterval) -> (main: String, fraction: String) {
        let negative = t < 0
        let hundredths = Int((abs(t) * 100).rounded(.down))
        let total = hundredths / 100
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        let main: String
        if h > 0 { main = String(format: "%d:%02d:%02d", h, m, s) }
        else if m > 0 { main = String(format: "%d:%02d", m, s) }
        else { main = String(s) }
        return ((negative ? "−" : "") + main, String(format: ".%02d", hundredths % 100))
    }

    static func time(_ t: TimeInterval?) -> String {
        guard let t else { return "-" }
        let c = clock(t)
        return c.main + c.fraction
    }

    static func delta(_ d: TimeInterval) -> String {
        let tenths = Int((abs(d) * 10).rounded())
        let total = tenths / 10
        let sign = d < 0 ? "−" : "+"
        let body: String
        if total >= 60 { body = String(format: "%d:%02d.%d", total / 60, total % 60, tenths % 10) }
        else { body = "\(total).\(tenths % 10)" }
        return sign + body
    }
}
