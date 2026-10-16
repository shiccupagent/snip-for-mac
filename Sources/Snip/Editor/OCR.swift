import CoreGraphics
import Foundation
import Vision

/// Pulls text out of a snip, like Snipping Tool's "Text actions".
enum OCR {
    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    var lines: [String] = []
                    for observation in request.results ?? [] {
                        if let best = observation.topCandidates(1).first { lines.append(best.string) }
                    }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
