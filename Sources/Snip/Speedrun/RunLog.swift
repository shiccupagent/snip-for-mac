import Foundation

/// The speedrun in a recording, saved next to it as "<recording>.speedrun.json". All "video" times are
/// seconds into the video. An AI (or a person) can fix split times here after watching the video, then
/// `snip speedrun render` redraws the timer into the video from the clean copy. See docs/SPEEDRUN-AI.md.
struct RunLog: Codable, Equatable {
    var version = 1
    /// The recording with the timer drawn in, and the same recording without it (both next to this file).
    var video: String
    var cleanVideo: String
    var game: String
    var category: String
    /// Where the clock starts, in seconds (negative counts down before the run).
    var offset: Double
    var timer: Placement
    /// Every attempt started during the recording, in order.
    var runs: [Run]

    struct Placement: Codable, Equatable {
        /// Top-left of the timer, in points from the video's top-left.
        var x: Double
        var y: Double
        /// Video pixels per point.
        var scale: Double
    }

    struct Run: Codable, Equatable {
        /// Which attempt this was (the counter in the timer's corner).
        var attempt: Int
        /// Video time the clock started (showed the offset, usually 0.00).
        var start: Double
        var segments: [Segment]
        /// Video time ranges the timer was paused.
        var pauses: [[Double]] = []
        /// Video time the attempt was reset (nil: it lasted to the end of the video).
        var reset: Double?
    }

    struct Segment: Codable, Equatable {
        var name: String
        /// Video time of this split (nil: not reached, or skipped).
        var split: Double?
        /// The comparison at the time of the run: personal-best split time and best segment (clock seconds).
        var pb: Double?
        var best: Double?
    }

    static func url(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("speedrun.json")
    }

    static func load(_ url: URL) throws -> RunLog {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RunLog.self, from: Data(contentsOf: url))
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Builds a RunLog from the live timer's events while recording.
@MainActor
final class RunLogBuilder {
    private(set) var runs: [RunLog.Run] = []
    private var pauseStart: Double?

    /// `videoTime` says how far into the video "now" is.
    func record(_ event: SpeedrunTimer.Event, splits: Splits, at videoTime: Double) {
        switch event {
        case .start:
            runs.append(RunLog.Run(attempt: splits.attempts, start: videoTime, segments: splits.segments.map {
                RunLog.Segment(name: $0.name, split: nil, pb: $0.pbSplit, best: $0.bestSegment)
            }))
        case .split(let i):
            setSplit(i, videoTime)
        case .undo(let i), .skip(let i):
            setSplit(i, nil)
        case .pause:
            pauseStart = videoTime
        case .resume:
            if let from = pauseStart, !runs.isEmpty { runs[runs.count - 1].pauses.append([from, videoTime]) }
            pauseStart = nil
        case .reset:
            closePause(at: videoTime)
            if !runs.isEmpty, runs[runs.count - 1].reset == nil { runs[runs.count - 1].reset = videoTime }
        }
    }

    /// A split renamed during the attempt being logged.
    func rename(_ i: Int, to name: String) {
        guard !runs.isEmpty, runs[runs.count - 1].reset == nil, runs[runs.count - 1].segments.indices.contains(i) else { return }
        runs[runs.count - 1].segments[i].name = name
    }

    /// Ends the log at the end of the video; a run still going stays open.
    func finish(at videoTime: Double) {
        closePause(at: videoTime)
    }

    private func closePause(at t: Double) {
        if let from = pauseStart, !runs.isEmpty { runs[runs.count - 1].pauses.append([from, t]) }
        pauseStart = nil
    }

    private func setSplit(_ i: Int, _ t: Double?) {
        guard !runs.isEmpty, runs[runs.count - 1].segments.indices.contains(i) else { return }
        runs[runs.count - 1].segments[i].split = t
    }
}

/// Plays a RunLog back on a timer whose clock is the video's time, so the timer can be drawn for
/// any frame. Times must only move forward.
@MainActor
final class RunReplay {
    let timer: SpeedrunTimer
    private var videoTime: Double = 0
    private var actions: [(time: Double, run: Int, perform: Action)] = []
    private var next = 0
    private let log: RunLog

    enum Action { case start, split, skip, pause, resume, reset }

    init(log: RunLog) {
        self.log = log
        let first = log.runs.first.map { RunReplay.splits(for: $0, in: log) } ?? Splits(game: log.game, category: log.category, segments: [])
        weak var owner: RunReplay?
        timer = SpeedrunTimer(splits: first) { owner?.videoTime ?? 0 }
        owner = self
        for (r, run) in log.runs.enumerated() {
            var list: [(Double, Action)] = [(run.start, .start)]
            var pending: [Int] = []
            for (i, segment) in run.segments.enumerated() {
                if let t = segment.split {
                    for _ in pending { list.append((t, .skip)) }
                    pending = []
                    list.append((t, .split))
                } else {
                    pending.append(i)
                }
            }
            for pause in run.pauses where pause.count == 2 {
                list.append((pause[0], .pause))
                list.append((pause[1], .resume))
            }
            if let reset = run.reset { list.append((reset, .reset)) }
            // Same-time actions keep their order: skips just before the split they lead to.
            let ordered = list.enumerated().sorted { a, b in
                a.element.0 != b.element.0 ? a.element.0 < b.element.0 : a.offset < b.offset
            }
            actions += ordered.map { (time: $0.element.0, run: r, perform: $0.element.1) }
        }
    }

    /// Moves the timer to `t` seconds into the video.
    func advance(to t: Double) {
        while next < actions.count, actions[next].time <= t {
            let action = actions[next]
            videoTime = action.time
            apply(action.perform, run: action.run)
            next += 1
        }
        videoTime = t
    }

    private func apply(_ action: Action, run: Int) {
        switch action {
        case .start:
            if timer.phase != .idle { timer.reset() }
            timer.replaceSplits(RunReplay.splits(for: log.runs[run], in: log))
            timer.split()
        case .split:
            if timer.phase == .paused { timer.togglePause() }
            timer.split()
        case .skip:
            timer.skip()
        case .pause:
            if timer.phase == .running { timer.togglePause() }
        case .resume:
            if timer.phase == .paused { timer.togglePause() }
        case .reset:
            timer.reset()
        }
    }

    /// The comparison splits as they were when `run` started.
    static func splits(for run: RunLog.Run, in log: RunLog) -> Splits {
        Splits(
            game: log.game,
            category: log.category,
            segments: run.segments.map { Segment(name: $0.name, pbSplit: $0.pb, bestSegment: $0.best) },
            attempts: max(run.attempt - 1, 0),
            offset: log.offset
        )
    }
}
