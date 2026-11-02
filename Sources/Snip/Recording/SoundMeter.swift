import AVFoundation
import MediaToolbox

/// Development aid for `dev-play`: listens to the sound a player item plays, before the volume is applied
/// (so a silent test still hears it), and keeps the loudest level of each chunk by video time. A test reads
/// the longest silence from it: a player that lost its sound shows a silence far longer than the pauses.
final class SoundMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [(time: Double, length: Double, peak: Float)] = []

    /// Starts listening to the first sound track of `item`.
    @MainActor
    func attach(to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<SoundMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: nil, unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
                var peak: Float = 0
                // Taps get 32-bit float samples.
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<Int(buffer.mDataByteSize) / 4 { peak = max(peak, abs(samples[i])) }
                }
                Unmanaged<SoundMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .record(time: range.start.seconds, length: range.duration.seconds, peak: peak)
            })
        // The macOS 26 SDK hands the tap back managed; earlier SDKs (CI's) hand it back unmanaged.
        #if compiler(>=6.2)
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr
        else { return }
        #else
        var created: Unmanaged<MTAudioProcessingTap>?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &created) == noErr,
              let tap = created?.takeRetainedValue() else { return }
        #endif
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        item.audioMix = mix
    }

    private func record(time: Double, length: Double, peak: Float) {
        guard time.isFinite, length.isFinite else { return }
        lock.lock()
        chunks.append((time, length, peak))
        lock.unlock()
    }

    /// The longest stretch of video time heard with the sound below about -50 dB.
    func longestSilence() -> (start: Double, length: Double) {
        lock.lock()
        let heard = chunks.sorted { $0.time < $1.time }
        lock.unlock()
        var best = (start: 0.0, length: 0.0)
        var runStart: Double?
        for chunk in heard {
            if chunk.peak < 0.003 {
                let start = runStart ?? chunk.time
                runStart = start
                if chunk.time + chunk.length - start > best.length { best = (start, chunk.time + chunk.length - start) }
            } else {
                runStart = nil
            }
        }
        return best
    }
}
