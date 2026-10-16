import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// What an AI (or a script) can do to recordings: list them, look at them (contact sheets and single
/// frames, so it can "watch" a video in seconds), and edit them (trim, cut out parts). Both
/// `Snip video …` (VideoCLI) and `Snip mcp` (MCPServer) are thin wrappers around this.
/// Edits replace the recording in place (the old file goes to the Trash), exactly like Save Edit in
/// the app, so speedrun timers and split times follow the cut.
@MainActor
enum VideoTools {
    struct ToolError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Finding recordings

    /// A recording, from its .mp4, its "(no timer)" copy, or its .speedrun.json.
    static func resolve(_ path: String) throws -> URL {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let name = url.lastPathComponent
        if name.hasSuffix(".speedrun.json") {
            url = url.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(".speedrun.json".count)) + ".mp4")
        } else if url.deletingPathExtension().lastPathComponent.hasSuffix(" (no timer)") {
            let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " (no timer)", with: "")
            url = url.deletingLastPathComponent().appendingPathComponent(base + ".mp4")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("no video at \(url.path)") }
        return url
    }

    struct Recording: Codable {
        let path: String
        let modified: String
        let speedrun: Bool
    }

    /// Recordings in Snip's recordings folder, newest first (the "(no timer)" copies left out).
    static func list(limit: Int = 20) -> [Recording] {
        let folder = Prefs.recordFolder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let videos = files.filter { $0.pathExtension.lowercased() == "mp4" && !$0.lastPathComponent.contains(" (no timer)") }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(max(limit, 1))
        let format = ISO8601DateFormatter()
        return videos.map { url, date in
            Recording(path: url.path, modified: format.string(from: date),
                      speedrun: FileManager.default.fileExists(atPath: RunLog.url(for: url).path))
        }
    }

    // MARK: Looking

    struct Info: Codable {
        let path: String
        let duration: Double
        let width: Int
        let height: Int
        let fps: Double
        let audioTracks: Int
        /// The speedrun log and clean copy, when the recording has a timer.
        let speedrunLog: String?
        let cleanVideo: String?
    }

    static func info(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video).first
        var size = CGSize.zero
        var fps = 0.0
        if let video {
            let natural = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let shown = natural.applying(transform)
            size = CGSize(width: abs(shown.width), height: abs(shown.height))
            fps = (Double(try await video.load(.nominalFrameRate)) * 100).rounded() / 100
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).count
        let logURL = RunLog.url(for: url)
        let log = try? RunLog.load(logURL)
        return Info(path: url.path, duration: duration, width: Int(size.width), height: Int(size.height), fps: fps,
                    audioTracks: audio, speedrunLog: log == nil ? nil : logURL.path,
                    cleanVideo: log.map { url.deletingLastPathComponent().appendingPathComponent($0.cleanVideo).path })
    }

    /// One frame, exactly at `time` (seconds), as a JPEG `width` pixels wide.
    static func frame(_ url: URL, at time: Double, width: Int = 960) async throws -> Data {
        let generator = generatorFor(url, width: width)
        let image = try await generator.image(at: CMTime(seconds: max(time, 0), preferredTimescale: 600)).image
        return try jpeg(image)
    }

    /// A grid of `count` frames evenly spread over `from`…`to`, each labelled with its time, so one
    /// look covers the whole stretch. Returns the JPEG and the frame times.
    static func contactSheet(_ url: URL, from: Double? = nil, to: Double? = nil, count: Int = 24,
                             columns: Int = 6, cellWidth: Int = 320) async throws -> (jpeg: Data, times: [Double]) {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let start = min(max(from ?? 0, 0), duration)
        let end = min(max(to ?? duration, start), duration)
        let count = min(max(count, 1), 120)
        let columns = min(max(columns, 1), count)
        let step = (end - start) / Double(count)
        let times = (0..<count).map { start + step * (Double($0) + 0.5) }

        let generator = generatorFor(url, width: cellWidth)
        var images: [CGImage] = []
        for t in times {
            images.append(try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
        }
        let first = images[0]
        let cellHeight = max(Int(Double(cellWidth) * Double(first.height) / Double(max(first.width, 1))), 1)
        let rows = (count + columns - 1) / columns
        let gap = 4
        let width = columns * cellWidth + (columns + 1) * gap
        let height = rows * cellHeight + (rows + 1) * gap
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError("couldn't make the contact sheet")
        }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let label: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(CGFloat(cellWidth) / 17, 11), weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        for (k, image) in images.enumerated() {
            let column = k % columns, row = k / columns
            let x = gap + column * (cellWidth + gap)
            let y = height - (row + 1) * (cellHeight + gap)
            context.draw(image, in: CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
            let text = NSAttributedString(string: " \(VideoTime.format(times[k])) ", attributes: label)
            let size = text.size()
            context.setFillColor(CGColor(gray: 0, alpha: 0.72))
            context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: size.width, height: size.height))
            text.draw(at: CGPoint(x: x, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let sheet = context.makeImage() else { throw ToolError("couldn't make the contact sheet") }
        return (try jpeg(sheet), times)
    }

    private static func generatorFor(_ url: URL, width: Int) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width * 4)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ToolError("couldn't encode the image")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ToolError("couldn't encode the image") }
        return data as Data
    }

    // MARK: Editing

    /// What to do to a recording. Times are seconds in the video as it is now.
    struct EditRequest {
        var keep: [ClosedRange<Double>] = []
        var cut: [ClosedRange<Double>] = []
        var trimStart: Double?
        var trimEnd: Double?
        var dryRun = false
    }

    struct EditResult: Codable {
        let path: String
        let saved: Bool
        let oldDuration: Double
        let newDuration: Double
        /// The parts kept, in the old video's seconds.
        let kept: [[Double]]
        let note: String?
    }

    static func edit(_ url: URL, _ request: EditRequest, status: @escaping (String) -> Void = { _ in }) async throws -> EditResult {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        var edit = TimelineEdit(duration: duration)
        if !request.keep.isEmpty, !edit.keep(request.keep) {
            throw ToolError("nothing to keep: every range is outside the video (0–\(VideoTime.format(duration)))")
        }
        if let t = request.trimStart, t > 0, !edit.trim(.start, at: t) { throw ToolError("trimming the start at \(t) s leaves nothing") }
        if let t = request.trimEnd, t < duration, !edit.trim(.end, at: t) { throw ToolError("trimming the end at \(t) s leaves nothing") }
        for range in request.cut {
            guard range.lowerBound < duration, range.upperBound > 0 else {
                throw ToolError("\(VideoTime.format(range.lowerBound))–\(VideoTime.format(range.upperBound)) is outside the video (0:00–\(VideoTime.format(duration)))")
            }
            if !edit.cut(range), edit.pieces.contains(where: { $0.overlaps(range) }) {
                throw ToolError("cutting \(VideoTime.format(range.lowerBound))–\(VideoTime.format(range.upperBound)) would leave nothing")
            }
        }
        let log = try? RunLog.load(RunLog.url(for: url))
        let note = log.flatMap { edit.cutsInsideRun($0) ? "A cut falls inside a speedrun run, so that run's time on the timer gets shorter." : nil }
        let kept = edit.pieces.map { [$0.lowerBound, $0.upperBound] }
        guard edit.isCut else {
            return EditResult(path: url.path, saved: false, oldDuration: duration, newDuration: duration, kept: kept, note: "Nothing to change.")
        }
        if !request.dryRun {
            try await VideoCutter.save(edit, log: log, video: url, status: status)
        }
        return EditResult(path: url.path, saved: !request.dryRun, oldDuration: duration, newDuration: edit.keptDuration, kept: kept, note: note)
    }

    /// "83.4", "1:23.4", "1:02:03" → seconds.
    static func time(_ text: String) throws -> Double {
        guard let t = VideoTime.parse(text) else { throw ToolError("\"\(text)\" isn't a time (use seconds or m:ss.s)") }
        return t
    }

    /// "1:20-1:35" or "80..95" → a range of seconds.
    static func range(_ text: String) throws -> ClosedRange<Double> {
        let parts = text.contains("..") ? text.components(separatedBy: "..") : text.components(separatedBy: "-")
        guard parts.count == 2 else { throw ToolError("\"\(text)\" isn't a range (use start-end, like 1:20-1:35)") }
        let from = try time(parts[0]), to = try time(parts[1])
        guard to > from else { throw ToolError("\"\(text)\" ends before it starts") }
        return from...to
    }
}
