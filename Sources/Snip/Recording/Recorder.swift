import AVFoundation
import CoreImage
import ScreenCaptureKit

/// Streams a region of a display (plus optional system audio and mic) into an .mp4.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Options {
        var systemAudio: Bool
        var microphone: Bool
        var fps: Int
    }

    let url: URL
    var onStreamError: (@MainActor (Error) -> Void)?
    /// A picture (the speedrun timer) drawn into every frame while it has one.
    var overlay: TimerOverlay?
    /// Also write the recording without the overlay here (so the timer can be redrawn later).
    var cleanURL: URL?

    private let queue = DispatchQueue(label: "snip.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var paused = false
    private var pauseBegan: CMTime?
    private var pauseOffset = CMTime.zero
    private var lastVideo: CMSampleBuffer?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Output pixels per display point, and the overlay's size factor (it's drawn at display scale).
    private var outputScale: CGFloat = 1
    private var overlayFit: CGFloat = 1
    /// The last captured screen and the last frame written with the overlay, for still screens and the end.
    private var lastSource: CVPixelBuffer?
    private var lastComposited: (buffer: CVPixelBuffer, time: CMTime)?
    private var sessionStart: CMTime?
    private var clean: (writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?, mic: AVAssetWriterInput?)?
    private var lastClean: CMSampleBuffer?

    init(url: URL) {
        self.url = url
    }

    /// `sourceRect` is in display points, top-left origin.
    func start(filter: SCContentFilter, sourceRect: CGRect, pixelScale: CGFloat, options: Options) async throws {
        // Keep within what H.264 can encode (about 4K).
        var w = sourceRect.width * pixelScale
        var h = sourceRect.height * pixelScale
        let fit = min(1, sqrt(8_294_400 / (w * h)), 4096 / w, 4096 / h)
        w *= fit
        h *= fit
        let pw = max(2, Int(w) / 2 * 2)
        let ph = max(2, Int(h) / 2 * 2)

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = pw
        config.height = ph
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 6
        if options.systemAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        if options.microphone, #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let bitrate = max(2_000_000, Int(Double(pw * ph) * Double(options.fps) * 0.12))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pw,
            AVVideoHeightKey: ph,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        videoInput = video
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pw,
            kCVPixelBufferHeightKey as String: ph,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        outputScale = CGFloat(pw) / sourceRect.width
        overlayFit = outputScale / pixelScale

        if options.systemAudio {
            let input = Recorder.aacInput(channels: 2)
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }
        if options.microphone, #available(macOS 15.0, *) {
            let input = Recorder.aacInput(channels: 1)
            if writer.canAdd(input) { writer.add(input); micInput = input }
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Snip", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't start the video file."])
        }
        self.writer = writer

        if let cleanURL {
            try? FileManager.default.removeItem(at: cleanURL)
            let cleanWriter = try AVAssetWriter(outputURL: cleanURL, fileType: .mp4)
            let cleanVideo = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            cleanVideo.expectsMediaDataInRealTime = true
            cleanWriter.add(cleanVideo)
            var cleanAudio: AVAssetWriterInput?
            var cleanMic: AVAssetWriterInput?
            if audioInput != nil {
                let input = Recorder.aacInput(channels: 2)
                if cleanWriter.canAdd(input) { cleanWriter.add(input); cleanAudio = input }
            }
            if micInput != nil {
                let input = Recorder.aacInput(channels: 1)
                if cleanWriter.canAdd(input) { cleanWriter.add(input); cleanMic = input }
            }
            if cleanWriter.startWriting() {
                clean = (cleanWriter, cleanVideo, cleanAudio, cleanMic)
            }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if options.microphone, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    private static func aacInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    func setPaused(_ pause: Bool) {
        queue.async { [self] in
            guard pause != paused else { return }
            if pause {
                pauseBegan = Recorder.hostNow()
                paused = true
            } else {
                if let began = pauseBegan {
                    pauseOffset = pauseOffset + (Recorder.hostNow() - began)
                }
                pauseBegan = nil
                paused = false
            }
        }
    }

    /// Stops capturing and finishes the file. Returns nil when nothing was recorded.
    func stop() async -> URL? {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let writer else {
                    continuation.resume(returning: nil)
                    return
                }
                guard sessionStarted, writer.status == .writing else {
                    clean?.writer.cancelWriting()
                    writer.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                let now = paused ? (pauseBegan ?? Recorder.hostNow()) : Recorder.hostNow()
                let end = now - pauseOffset
                // Repeat the last frame at the end so a still screen still lasts the full length.
                if let last = lastComposited, let adaptor, end > last.time, adaptor.assetWriterInput.isReadyForMoreMediaData {
                    adaptor.append(last.buffer, withPresentationTime: end)
                } else if let last = lastVideo, let input = videoInput, end > last.presentationTimeStamp,
                   input.isReadyForMoreMediaData, let copy = Recorder.retimed(last, to: end) {
                    input.append(copy)
                }
                writer.endSession(atSourceTime: end)
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                micInput?.markAsFinished()
                let group = DispatchGroup()
                if let clean {
                    if let last = lastClean, end > last.presentationTimeStamp, clean.video.isReadyForMoreMediaData,
                       let copy = Recorder.retimed(last, to: end) {
                        clean.video.append(copy)
                    }
                    clean.writer.endSession(atSourceTime: end)
                    clean.video.markAsFinished()
                    clean.audio?.markAsFinished()
                    clean.mic?.markAsFinished()
                    group.enter()
                    clean.writer.finishWriting { group.leave() }
                }
                let url = self.url
                group.enter()
                writer.finishWriting { group.leave() }
                group.notify(queue: queue) {
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }

    /// How far into the video "now" is, in seconds (0 until the first frame arrives).
    func videoTime() -> Double {
        queue.sync {
            guard let sessionStart else { return 0 }
            let now = paused ? (pauseBegan ?? Recorder.hostNow()) : Recorder.hostNow()
            return max(0, (now - pauseOffset - sessionStart).seconds)
        }
    }

    /// Video pixels per display point.
    var pixelsPerPoint: CGFloat { outputScale }

    /// Whether the clean copy (cleanURL) was written.
    var wroteClean: Bool { queue.sync { clean?.writer.status == .completed } }

        // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !paused, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw),
                  let input = videoInput else { return }
            let drawn = overlay?.content
            if status == .complete, let source = CMSampleBufferGetImageBuffer(sampleBuffer) {
                lastSource = source
            } else if !(status == .idle && drawn != nil && sessionStarted) {
                // A still screen sends no new frames; only a running timer needs them redrawn.
                return
            }
            if !sessionStarted {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                clean?.writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStart = sampleBuffer.presentationTimeStamp
                sessionStarted = true
            }
            if status == .complete, let clean, clean.video.isReadyForMoreMediaData,
               let buffer = Recorder.shifted(sampleBuffer, by: pauseOffset), clean.video.append(buffer) {
                lastClean = buffer
            }
            guard input.isReadyForMoreMediaData, sampleBuffer.presentationTimeStamp.isValid else { return }
            if let drawn, let source = lastSource, let adaptor, let frame = composite(drawn.image, at: drawn.offset, over: source) {
                let time = sampleBuffer.presentationTimeStamp - pauseOffset
                if time > (lastComposited?.time ?? .negativeInfinity), adaptor.append(frame, withPresentationTime: time) {
                    lastComposited = (frame, time)
                    lastVideo = nil
                }
            } else if status == .complete, let buffer = Recorder.shifted(sampleBuffer, by: pauseOffset) {
                if input.append(buffer) {
                    lastVideo = buffer
                    lastComposited = nil
                }
            }
        case .audio:
            append(sampleBuffer, to: audioInput)
            append(sampleBuffer, to: clean?.audio)
        default:
            if #available(macOS 15.0, *), type == .microphone {
                append(sampleBuffer, to: micInput)
                append(sampleBuffer, to: clean?.mic)
            }
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard sessionStarted, let input, input.isReadyForMoreMediaData,
              let buffer = Recorder.shifted(sampleBuffer, by: pauseOffset) else { return }
        input.append(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.onStreamError?(error)
        }
    }

    /// The captured screen with `image` drawn with its top-left `offset` points from the frame's top-left.
    private func composite(_ image: CGImage, at offset: CGPoint, over source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = adaptor?.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let frame = out else { return nil }
        CVBufferPropagateAttachments(source, frame)
        let base = CIImage(cvPixelBuffer: source)
        let extent = base.extent
        let height = CGFloat(image.height) * overlayFit
        let timer = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: overlayFit, y: overlayFit))
            .transformed(by: CGAffineTransform(translationX: offset.x * outputScale, y: extent.maxY - offset.y * outputScale - height))
        ciContext.render(timer.composited(over: base), to: frame, bounds: extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return frame
    }

    // MARK: Timing helpers

    private static func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private static func shifted(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return buffer }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
            sampleTimingArray: &timing, sampleBufferOut: &out
        )
        return out
    }

    private static func retimed(_ buffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &out
        )
        return out
    }
}
