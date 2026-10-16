import Foundation
@MainActor func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { failures += 1 } }
@MainActor var failures = 0
MainActor.assumeIsolated {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    var s = try! Splits(lss: Data(contentsOf: url))
    check(s.game == "Test Game" && s.category == "Any%" && s.attempts == 7, "header parsed")
    check(abs(s.offset + 1.5) < 1e-9, "negative offset parsed")
    check(s.segments.map(\.name) == ["Level 1", "Level 2"], "segment names")
    check(s.segments[0].pbSplit == 20 && s.segments[1].pbSplit == 60 && s.segments[0].bestSegment == 18.5, "pb + golds")
    check(s.sumOfBest == 57.5 && s.pbTime == 60 && s.pbSegment(1) == 40, "derived sums")
    check(LSSTime.format(83.456) == "00:01:23.4560000" && LSSTime.parse("1.02:03:04.5") == 93784.5, "time format/parse")

    // Round trip with edits: rename, insert a new segment between, keep icons/history/autosplitter.
    s.segments[0].name = "World 1"
    s.segments.insert(Segment(name: "Bonus"), at: 1)
    s.attempts = 8
    let out = String(data: s.lssData(), encoding: .utf8)!
    check(out.contains("ICONDATA1") && out.contains("<Setting>keepme</Setting>") && out.contains("<Attempt id=\"1\""), "unknown parts preserved")
    check(out.contains("<GameTime>00:00:19.0000000</GameTime>"), "game time preserved")
    let again = try! Splits(lss: out.data(using: .utf8)!)
    check(again.segments.map(\.name) == ["World 1", "Bonus", "Level 2"] && again.attempts == 8, "edits round-trip")
    check(again.segments[1].pbSplit == nil && again.segments[2].pbSplit == 60, "new segment empty, others intact")
    check(out.components(separatedBy: "ICONDATA1").count == 2, "icon not duplicated")
    let blankOut = Splits.blank.lssData()
    check((try? Splits(lss: blankOut))?.segments.map(\.name) == ["Finish"], "blank splits write a valid file")
    check((try? Splits(lss: Data("<foo/>".utf8))) == nil, "rejects non-LiveSplit XML")

    // Timer rules.
    let t = SpeedrunTimer(splits: Splits(game: "G", category: "C", segments: [Segment(name: "A", pbSplit: 5, bestSegment: 4), Segment(name: "B", pbSplit: 10, bestSegment: 9)]))
    var saved: Splits?
    t.onSplitsChanged = { saved = $0 }
    t.split(); check(t.phase == .running && t.splits.attempts == 1, "split starts, counts attempt")
    Thread.sleep(forTimeInterval: 0.02); t.split()
    check(t.index == 1 && (t.times[0] ?? 99) < 1, "split recorded")
    check(t.standing(0) == .gold, "faster than best segment is gold")
    t.togglePause(); let p1 = t.now; Thread.sleep(forTimeInterval: 0.05); check(abs(t.now - p1) < 0.001 && t.phase == .paused, "pause freezes clock")
    t.split(); check(t.phase == .running, "split while paused resumes")
    t.undo(); check(t.index == 0 && t.times[0] == nil, "undo")
    t.split(); t.split(); check(t.phase == .ended, "last split ends run")
    check(t.timerStanding == .personalBest, "new PB is blue")
    t.reset()
    check(t.phase == .idle && (saved?.segments[1].pbSplit ?? 99) < 5 && (saved?.segments[0].bestSegment ?? 9) < 4, "reset saves PB + golds")
    check(SpeedrunFormat.delta(-0.44) == "−0.4" && SpeedrunFormat.delta(75.3) == "+1:15.3", "delta format")
    check(SpeedrunFormat.time(83.456) == "1:23.45" && SpeedrunFormat.clock(3723.4).main == "1:02:03", "clock format")

    // Run log: live events → JSON → replay on video time gives the same splits.
    var video = 0.0
    let live = SpeedrunTimer(splits: Splits(game: "G", category: "C", segments: [Segment(name: "A", pbSplit: 5, bestSegment: 4), Segment(name: "B"), Segment(name: "C", pbSplit: 20)])) { video }
    let builder = RunLogBuilder()
    live.onEvent = { builder.record($0, splits: live.splits, at: video) }
    video = 1; live.split()                    // start at video 1
    video = 4; live.split()                    // A at clock 3
    video = 6; live.togglePause()
    video = 8; live.togglePause()              // paused 2 s
    video = 9; live.skip()                     // skip B
    video = 12; live.split()                   // C at clock 9 (11 − 2 paused)
    check(live.phase == .ended && live.times[2] == 9, "live run with pause and skip")
    video = 13; live.reset()
    builder.finish(at: 14)
    let log = RunLog(video: "v.mp4", cleanVideo: "v (no timer).mp4", game: "G", category: "C", offset: 0,
                     timer: .init(x: 10, y: 8, scale: 2), runs: builder.runs)
    check(builder.runs.count == 1 && builder.runs[0].start == 1 && builder.runs[0].segments.map(\.split) == [4, nil, 12]
          && builder.runs[0].pauses == [[6, 8]] && builder.runs[0].reset == 13 && builder.runs[0].attempt == 1, "log records run")
    let json = String(data: try! log.data(), encoding: .utf8)!
    check(json.contains("\"clean_video\"") && json.contains("\"pauses\""), "log JSON uses snake_case")
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runlog-test.json")
    try! log.data().write(to: tmp)
    check((try? RunLog.load(tmp)) == log, "log JSON round-trips")
    let replay = RunReplay(log: log)
    replay.advance(to: 0.5); check(replay.timer.phase == .idle, "replay idle before start")
    replay.advance(to: 3); check(replay.timer.phase == .running && abs(replay.timer.now - 2) < 1e-9, "replay clock follows video")
    replay.advance(to: 7); check(replay.timer.phase == .paused && abs(replay.timer.now - 5) < 1e-9, "replay pause")
    replay.advance(to: 12.5); check(replay.timer.phase == .ended && replay.timer.times.map { $0 } == [3, nil, 9], "replay matches live splits")
    replay.advance(to: 13.5); check(replay.timer.phase == .idle, "replay reset")
    // An AI moves split C to 11 s and fills in B at 10 s.
    var fixed = log
    fixed.runs[0].segments[1].split = 10
    fixed.runs[0].segments[2].split = 11
    let replay2 = RunReplay(log: fixed)
    replay2.advance(to: 11.5); check(replay2.timer.times.map { $0 } == [3, 7, 8] && replay2.timer.phase == .ended, "edited log replays")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
