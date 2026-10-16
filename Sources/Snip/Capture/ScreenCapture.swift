import AppKit
import ScreenCaptureKit

/// One physical display, with a frozen frame of what was on it when the snip started.
struct DisplayShot {
    let screen: NSScreen
    let display: SCDisplay
    let image: CGImage

    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }

    /// The display's frame in global CoreGraphics coordinates (top-left origin).
    var cgFrame: CGRect { CGDisplayBounds(display.displayID) }
}

struct WindowInfo {
    /// Global CoreGraphics coordinates (top-left origin).
    let cgFrame: CGRect
}

enum ScreenCapture {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    @MainActor
    static func freezeDisplays() async throws -> [DisplayShot] {
        let content = try await content()
        var shots: [DisplayShot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(DisplayShot(screen: screen, display: display, image: image))
        }
        if shots.isEmpty {
            throw NSError(domain: "Snip", code: 1, userInfo: [NSLocalizedDescriptionKey: "No displays could be captured."])
        }
        return shots
    }

    /// Normal app windows on screen, front to back.
    static func visibleWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 40, frame.height > 40 else { return nil }
            return WindowInfo(cgFrame: frame)
        }
    }

    /// Crops a frozen display frame. `rect` is in display-local points, top-left origin.
    static func crop(_ shot: DisplayShot, rect: CGRect) -> CGImage? {
        let s = shot.scale
        let pixels = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
            .integral
            .intersection(CGRect(origin: .zero, size: shot.image.pixelSize))
        guard !pixels.isEmpty else { return nil }
        return shot.image.cropping(to: pixels)
    }

    /// Crops to the bounding box of a lasso path and makes everything outside it transparent.
    static func cropFreeform(_ shot: DisplayShot, path: CGPath) -> CGImage? {
        let s = shot.scale
        var transform = CGAffineTransform(scaleX: s, y: s)
        guard let scaled = path.copy(using: &transform) else { return nil }
        let box = scaled.boundingBoxOfPath.integral.intersection(CGRect(origin: .zero, size: shot.image.pixelSize))
        guard !box.isEmpty, let sub = shot.image.cropping(to: box),
              let ctx = CGContext(
                data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.addPath(scaled)
        ctx.clip()
        ctx.drawUpright(sub, in: box)
        return ctx.makeImage()
    }
}
