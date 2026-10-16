import AppKit
import AVFoundation
import CoreImage
import SwiftUI

/// `Snip speedrun …`: lets an AI (or a person) re-time a recorded run. The recording's splits live in
/// "<recording>.speedrun.json"; edit the video times there, then `render` redraws the timer.
/// Workflow and file format: docs/SPEEDRUN-AI.md.
@MainActor
enum SpeedrunCLI {
    static let usage = """
    Usage: snip speedrun <command>

      list                      Recordings with a speedrun, newest first
      show <recording> [--json] The runs and split times in a recording
      render <recording> [--out <file.mp4>]
                                Redraw the timer from the .speedrun.json (after fixing split times).
                                Replaces the recording (the old one goes to the Trash) unless --out is given.

    <recording> is the .mp4, its "(no timer).mp4" copy, or its .speedrun.json.
    Times in the .speedrun.json are seconds into the video. Guide: docs/SPEEDRUN-AI.md in the Snip repo.
    """

    /// Runs the command and returns the exit status.
    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else {
            print(usage)
            return 0
        }
        do {
            switch command {
            case "list":
                list()
            case "show":
                guard args.count >= 2 else { throw CLIError("show needs a recording") }
                try show(logURL: resolve(args[1]), json: args.contains("--json"))
            case "render":
                guard args.count >= 2 else { throw CLIError("render needs a recording") }
                let logURL = try resolve(args[1])
                let out = args.firstIndex(of: "--out").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
                try await render(logURL: logURL, out: out)
            case "help", "--help", "-h":
                print(usage)
            default:
                throw CLIError("unknown command \"\(command)\"\n\n\(usage)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("snip speedrun: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    struct CLIError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The .speedrun.json for a recording, its clean copy, or the log itself.
    static func resolve(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var candidates = [url]
        if !url.path.hasSuffix(".speedrun.json") {
            let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " (no timer)", with: "")
            candidates = [url.deletingLastPathComponent().appendingPathComponent(base + ".speedrun.json")]
        }
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CLIError("no speedrun log at \(candidates[0].path)")
        }
        return found
    }

    // MARK: list / show

    static func list() {
        let folder = Prefs.recordFolder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let logs = files.filter { $0.lastPathComponent.hasSuffix(".speedrun.json") }
            .sorted { modified($0) > modified($1) }
        if logs.isEmpty {
            print("No speedrun recordings in \(folder.path)")
            return
        }
        for url in logs {
            guard let log = try? RunLog.load(url) else { continue }
            let title = [log.game, log.category].filter { !$0.isEmpty }.joined(separator: " – ")
            print("\(folder.appendingPathComponent(log.video).path)\n    \(title.isEmpty ? "Untitled" : title), \(log.runs.count) run(s)")
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func show(logURL: URL, json: Bool) throws {
        if json {
            print(String(decoding: try Data(contentsOf: logURL), as: UTF8.self))
            return
        }
        let log = try RunLog.load(logURL)
        print("\(log.game.isEmpty ? "Untitled" : log.game) – \(log.category)")
        print("Video: \(logURL.deletingLastPathComponent().appendingPathComponent(log.video).path)")
        print("Clean copy (scrub this one): \(logURL.deletingLastPathComponent().appendingPathComponent(log.cleanVideo).path)")
        print("Log (edit this): \(logURL.path)")
        for (r, run) in log.runs.enumerated() {
            let replay = RunReplay(log: RunLog(video: log.video, cleanVideo: log.cleanVideo, game: log.game, category: log.category,
                                               offset: log.offset, timer: log.timer, runs: [run]))
            let end = ([run.reset] + run.segments.map(\.split) + run.pauses.flatMap { $0 }).compactMap { $0 }.max() ?? run.start
            replay.advance(to: end)
            print("\nRun \(r + 1) (attempt \(run.attempt)): clock starts at video \(clock(run.start))" + (run.reset.map { ", reset at \(clock($0))" } ?? ""))
            for (i, segment) in run.segments.enumerated() {
                let at = segment.split.map { "video \(clock($0))" } ?? "—"
                let time = replay.timer.times.indices.contains(i) ? replay.timer.times[i] : nil
                let delta = replay.timer.delta(i).map { "  " + SpeedrunFormat.delta($0) } ?? ""
                print("  \(i + 1). \(segment.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(at.padding(toLength: 18, withPad: " ", startingAt: 0)) clock \(SpeedrunFormat.time(time))\(delta)")
            }
            if !run.pauses.isEmpty {
                print("  Paused: " + run.pauses.map { "\(clock($0.first ?? 0))–\(clock($0.last ?? 0))" }.joined(separator: ", "))
            }
        }
    }

    private static func clock(_ t: Double) -> String {
        String(format: "%d:%06.3f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    // MARK: render

    static func render(logURL: URL, out: URL?) async throws {
        print("Rendering…")
        let destination = try await SpeedrunRenderer.rerender(logURL: logURL, to: out) { fraction in
            print(String(format: "  %3.0f%%", fraction * 100))
        }
        print("Done: \(destination.path)")
    }
}

/// Redraws the timer onto the clean copy of a recording, frame by frame, from a RunLog.
@MainActor
final class SpeedrunRenderer {
    let log: RunLog
    let source: URL
    let output: URL
    private let replay: RunReplay
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Redraws the timer described by the log at `logURL` onto its clean copy. Writes `out`, or replaces the
    /// recording (the old file goes to the Trash). Returns where the result went.
    @discardableResult
    static func rerender(logURL: URL, to out: URL? = nil, progress: @escaping (Double) -> Void) async throws -> URL {
        let log = try RunLog.load(logURL)
        let folder = logURL.deletingLastPathComponent()
        let source = folder.appendingPathComponent(log.cleanVideo)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw SpeedrunCLI.CLIError("the copy without the timer is missing: \(source.path)")
        }
        let destination = out ?? folder.appendingPathComponent(log.video)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".snip-render-\(UUID().uuidString).mp4")
        do {
            try await SpeedrunRenderer(log: log, source: source, output: temp).run(progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    init(log: RunLog, source: URL, output: URL) {
        self.log = log
        self.source = source
        self.output = output
        replay = RunReplay(log: log)
    }

    func run(progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SpeedrunCLI.CLIError("no video in \(source.lastPathComponent)")
        }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let dataRate = try await track.load(.estimatedDataRate)
        let fps = try await track.load(.nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOuts: [AVAssetReaderTrackOutput] = []
        for audio in audioTracks {
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            reader.add(output)
            audioOuts.append(output)
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let width = Int(size.width), height = Int(size.height)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, Int(dataRate * 1.1)),
                AVVideoExpectedSourceFrameRateKey: max(1, Int(fps.rounded())),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(videoIn)
        var audioIns: [AVAssetWriterInput] = []
        for audio in audioTracks {
            let format = try await audio.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIns.append(input)
        }

        guard reader.startReading() else { throw reader.error ?? SpeedrunCLI.CLIError("couldn't read the video") }
        guard writer.startWriting() else { throw writer.error ?? SpeedrunCLI.CLIError("couldn't write the video") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let failure = FailureBox()

        // Audio is copied as it is.
        for (output, input) in zip(audioOuts, audioIns) {
            group.enter()
            let queue = DispatchQueue(label: "snip.render.audio")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    input.append(sample)
                }
            }
        }

        // Video: draw the replayed timer onto each frame.
        group.enter()
        let videoQueue = DispatchQueue(label: "snip.render.video")
        var lastReport = -1
        videoIn.requestMediaDataWhenReady(on: videoQueue) { [self] in
            while videoIn.isReadyForMoreMediaData {
                guard let sample = videoOut.copyNextSampleBuffer() else {
                    videoIn.markAsFinished()
                    group.leave()
                    return
                }
                let time = sample.presentationTimeStamp
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                let picture = DispatchQueue.main.sync { MainActor.assumeIsolated { self.timerImage(at: time.seconds) } }
                guard let frame = self.composite(picture, over: pixels, pool: adaptor.pixelBufferPool) else {
                    failure.set(SpeedrunCLI.CLIError("couldn't draw frame at \(time.seconds) s"))
                    reader.cancelReading()
                    videoIn.markAsFinished()
                    group.leave()
                    return
                }
                adaptor.append(frame, withPresentationTime: time)
                let percent = duration > 0 ? Int(time.seconds / duration * 20) : 0
                if percent > lastReport {
                    lastReport = percent
                    DispatchQueue.main.async { progress(min(1, Double(percent) / 20)) }
                }
            }
        }

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            group.notify(queue: .main) { done.resume() }
        }
        if let error = failure.error { writer.cancelWriting(); throw error }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? SpeedrunCLI.CLIError("reading failed") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SpeedrunCLI.CLIError("writing failed") }
    }

    private func timerImage(at t: Double) -> CGImage? {
        replay.advance(to: t)
        let renderer = ImageRenderer(content: TimerView(timer: replay.timer, live: false))
        renderer.scale = log.timer.scale
        return renderer.cgImage
    }

    nonisolated private func composite(_ image: CGImage?, over source: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let frame = out else { return nil }
        CVBufferPropagateAttachments(source, frame)
        let base = CIImage(cvPixelBuffer: source)
        var picture = base
        if let image {
            let scale = log.timer.scale
            let timer = CIImage(cgImage: image).transformed(by: CGAffineTransform(
                translationX: log.timer.x * scale,
                y: base.extent.maxY - log.timer.y * scale - CGFloat(image.height)
            ))
            picture = timer.composited(over: base)
        }
        ciContext.render(picture, to: frame, bounds: base.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return frame
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    var error: Error? { lock.withLock { _error } }
    func set(_ error: Error) { lock.withLock { if _error == nil { _error = error } } }
}
