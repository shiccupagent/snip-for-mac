import AVFoundation

/// What a video window plays. Some video editors write sound with holes: one packet stamped as lasting
/// seconds when it holds a few milliseconds. AVPlayer goes silent at a hole of about two seconds and stays
/// silent until playback restarts (a tutorial render, 2026-11-02: silent from 2:53 on; its 1.2 s hole played
/// through). A file with holes plays through a composition in which each hole is an empty stretch: real
/// silence, with the sound after it exactly where the file puts it. Finding holes reads only the packet
/// table (12,000 packets in about 1 ms); files without any play as they are.
@MainActor
enum PlaybackItem {
    static func make(_ url: URL) async -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        if let bridged = try? await bridgingSoundHoles(in: asset) {
            return AVPlayerItem(asset: bridged)
        }
        return AVPlayerItem(asset: asset)
    }

    /// `asset` with every sound hole left empty, or nil when it has none.
    static func bridgingSoundHoles(in asset: AVAsset) async throws -> AVComposition? {
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var holes: [CMPersistentTrackID: [CMTimeRange]] = [:]
        for track in audio {
            let found = try await soundHoles(in: track)
            if !found.isEmpty { holes[track.trackID] = found }
        }
        guard !holes.isEmpty else { return nil }
        let composition = AVMutableComposition()
        for track in try await asset.loadTracks(withMediaType: .video) + audio {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            copy.preferredTransform = try await track.load(.preferredTransform)
            let range = try await track.load(.timeRange)
            var start = range.start
            for hole in holes[track.trackID] ?? [] {
                if hole.start > start {
                    try copy.insertTimeRange(CMTimeRange(start: start, end: hole.start), of: track, at: start)
                }
                start = hole.end
            }
            if range.end > start {
                try copy.insertTimeRange(CMTimeRange(start: start, end: range.end), of: track, at: start)
            }
        }
        return composition
    }

    /// The stretches of `track`'s timeline that a packet claims but holds no sound for.
    static func soundHoles(in track: AVAssetTrack) async throws -> [CMTimeRange] {
        // Only compressed sound has packets of a fixed length to measure against (and few enough to read).
        guard try await track.load(.canProvideSampleCursors),
              let format = try await track.load(.formatDescriptions).first,
              let sound = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              sound.mFramesPerPacket > 1, sound.mSampleRate > 0,
              let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return [] }
        // The cursor counts in the file's own time; the track may shift it (the encoder's start-up delay).
        let segments = try await track.load(.segments).filter { !$0.isEmpty }
        guard segments.count == 1, let mapping = segments.first?.timeMapping,
              mapping.source.duration == mapping.target.duration else { return [] }
        let shift = mapping.target.start - mapping.source.start
        let packet = CMTime(value: CMTimeValue(sound.mFramesPerPacket), timescale: CMTimeScale(sound.mSampleRate))
        let range = try await track.load(.timeRange)
        var holes: [CMTimeRange] = []
        var packets = 0
        repeat {
            let claimed = cursor.currentSampleDuration
            if (claimed - packet).seconds > 0.005 {
                let hole = CMTimeRange(start: cursor.presentationTimeStamp + shift + packet, duration: claimed - packet)
                    .intersection(range)
                if !hole.isEmpty { holes.append(hole) }
            }
            packets += 1
        } while packets < 2_000_000 && cursor.stepInDecodeOrder(byCount: 1) == 1
        return holes
    }
}
