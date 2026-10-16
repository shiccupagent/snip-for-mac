import AVFoundation
import Foundation

/// Saves a timeline edit. The recording is re-encoded keeping only the kept parts and replaces the
/// file in place (the old one goes to the Trash), so there is never a second copy to keep track of.
/// A speedrun recording cuts its clean copy instead, moves the run log onto the new times, and
/// redraws the timer from them.
@MainActor
enum VideoCutter {
    static func save(_ edit: TimelineEdit, log: RunLog?, video: URL, status: @escaping (String) -> Void) async throws {
        guard var log else {
            if edit.isCut { try await replace(video, keeping: edit.pieces) { status("Saving the edit… \(percent($0))") } }
            return
        }
        let logURL = RunLog.url(for: video)
        let clean = video.deletingLastPathComponent().appendingPathComponent(log.cleanVideo)
        let hasClean = FileManager.default.fileExists(atPath: clean.path)
        if edit.isCut {
            try await replace(hasClean ? clean : video, keeping: edit.pieces) { status("Cutting the video… \(percent($0))") }
            log = edit.apply(to: log)
        }
        try log.data().write(to: logURL, options: .atomic)
        if hasClean {
            _ = try await SpeedrunRenderer.rerender(logURL: logURL, to: video) { status("Redrawing the timer… \(percent($0))") }
        }
    }

    private static func percent(_ fraction: Double) -> String { "\(Int(min(max(fraction, 0), 1) * 100))%" }

    /// Re-encodes `file` keeping only `pieces`, then swaps the result in; the old file goes to the Trash.
    static func replace(_ file: URL, keeping pieces: [ClosedRange<Double>], progress: @escaping (Double) -> Void) async throws {
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.deletingPathExtension().lastPathComponent) (editing).mp4")
        try? FileManager.default.removeItem(at: temp)
        do {
            try await export(file, keeping: pieces, to: temp, progress: progress)
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            try FileManager.default.moveItem(at: temp, to: file)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Writes `source` with only `pieces` (seconds, in order) to `dest`: picture, computer sound and mic.
    static func export(_ source: URL, keeping pieces: [ClosedRange<Double>], to dest: URL,
                       progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let length = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let into = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            into.preferredTransform = try await track.load(.preferredTransform)
            let trackRange = try await track.load(.timeRange)
            var at = CMTime.zero
            for piece in pieces {
                let start = CMTime(seconds: piece.lowerBound, preferredTimescale: 600)
                let end = CMTimeMinimum(CMTime(seconds: piece.upperBound, preferredTimescale: 600), length)
                guard end > start else { continue }
                let range = CMTimeRange(start: start, end: end)
                // A track that starts late or ends early (the mic, say) only gives what it has.
                let part = range.intersection(trackRange)
                if !part.isEmpty {
                    try into.insertTimeRange(part, of: track, at: at + (part.start - range.start))
                }
                at = at + range.duration
            }
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Snip", code: 5, userInfo: [NSLocalizedDescriptionKey: "This Mac can't re-encode the video."])
        }
        // A video composition makes the export re-encode every frame. Without one, AVFoundation copies
        // the original frames and hides the extra ones around each cut in an edit list, which some
        // players and upload sites show as a glitch.
        session.videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        session.outputURL = dest
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { ticker.cancel() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        guard session.status == .completed else {
            throw session.error ?? NSError(domain: "Snip", code: 6, userInfo: [NSLocalizedDescriptionKey: "The video couldn't be saved."])
        }
    }
}
