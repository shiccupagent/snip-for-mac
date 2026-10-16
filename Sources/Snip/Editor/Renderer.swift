import AppKit

/// Draws a snip and its markup. All drawing happens in image pixel space with the y axis pointing down,
/// so the editor canvas and the exported image share the same code.
enum Renderer {
    static func renderScene(in ctx: CGContext, image: CGImage, annotations: [Annotation]) {
        ctx.drawUpright(image, in: CGRect(origin: .zero, size: image.pixelSize))
        for a in annotations {
            draw(a, in: ctx, base: image)
        }
    }

    @MainActor
    static func export(_ doc: EditorDocument) -> CGImage? {
        let r = doc.crop.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0 else { return nil }
        let space = (doc.image.colorSpace?.model == .rgb ? doc.image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        ctx.interpolationQuality = .high

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        renderScene(in: ctx, image: doc.image, annotations: doc.annotations)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func draw(_ a: Annotation, in ctx: CGContext, base: CGImage) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch a.tool {
        case .pen, .highlighter, .line, .rect, .ellipse:
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(a.width)
            let color = a.tool == .highlighter ? a.color.withAlphaComponent(0.42) : a.color
            ctx.setStrokeColor(color.cgColor)
            ctx.addPath(shapePath(a))
            ctx.strokePath()
        case .arrow:
            guard a.points.count >= 2 else { return }
            let (shaftEnd, head) = arrowGeometry(from: a.points[0], to: a.points[1], width: a.width)
            ctx.setLineCap(.round)
            ctx.setLineWidth(a.width)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.move(to: a.points[0])
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
            ctx.setFillColor(a.color.cgColor)
            ctx.setLineJoin(.round)
            ctx.addPath(head)
            ctx.drawPath(using: .fillStroke)
        case .redact:
            pixelate(base, rect: rect(of: a), in: ctx)
        case .text:
            guard let origin = a.points.first, !a.text.isEmpty else { return }
            let str = NSAttributedString(string: a.text, attributes: textAttributes(a))
            str.draw(with: CGRect(origin: origin, size: textSize(a)), options: [.usesLineFragmentOrigin])
        case .eraser, .crop:
            break
        }
    }

    // MARK: Geometry

    static func rect(of a: Annotation) -> CGRect {
        guard a.points.count >= 2 else { return .zero }
        let p = a.points[0], q = a.points[1]
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
    }

    static func shapePath(_ a: Annotation) -> CGPath {
        switch a.tool {
        case .pen, .highlighter:
            return smoothPath(a.points)
        case .line, .arrow:
            let p = CGMutablePath()
            if a.points.count >= 2 {
                p.move(to: a.points[0])
                p.addLine(to: a.points[1])
            }
            return p
        case .ellipse:
            return CGPath(ellipseIn: rect(of: a), transform: nil)
        default:
            return CGPath(rect: rect(of: a), transform: nil)
        }
    }

    /// Joins pen points with quadratic curves through their midpoints, so strokes look smooth.
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: first)
            return path
        }
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func arrowGeometry(from s: CGPoint, to e: CGPoint, width: CGFloat) -> (CGPoint, CGPath) {
        let angle = atan2(e.y - s.y, e.x - s.x)
        let length = max(width * 3.6, 14)
        let half = length * 0.55
        let back = CGPoint(x: e.x - cos(angle) * length, y: e.y - sin(angle) * length)
        let left = CGPoint(x: back.x + cos(angle + .pi / 2) * half, y: back.y + sin(angle + .pi / 2) * half)
        let right = CGPoint(x: back.x - cos(angle + .pi / 2) * half, y: back.y - sin(angle + .pi / 2) * half)
        let head = CGMutablePath()
        head.move(to: e)
        head.addLine(to: left)
        head.addLine(to: right)
        head.closeSubpath()
        let shaftEnd = CGPoint(x: e.x - cos(angle) * length * 0.7, y: e.y - sin(angle) * length * 0.7)
        return (shaftEnd, head)
    }

    static func textAttributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold),
            .foregroundColor: a.color,
        ]
    }

    static func textSize(_ a: Annotation) -> CGSize {
        let r = (a.text as NSString).boundingRect(
            with: CGSize(width: 100_000, height: 100_000),
            options: [.usesLineFragmentOrigin],
            attributes: textAttributes(a)
        )
        return CGSize(width: ceil(r.width) + 2, height: ceil(r.height))
    }

    static func textRect(_ a: Annotation) -> CGRect {
        CGRect(origin: a.points.first ?? .zero, size: textSize(a))
    }

    static func hitTest(_ a: Annotation, at p: CGPoint, tolerance: CGFloat) -> Bool {
        switch a.tool {
        case .text:
            return textRect(a).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .redact:
            return rect(of: a).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        default:
            let hit = shapePath(a).copy(
                strokingWithWidth: a.width + tolerance * 2,
                lineCap: .round, lineJoin: .round, miterLimit: 10
            )
            return hit.contains(p)
        }
    }

    // MARK: Redact

    static func pixelate(_ image: CGImage, rect: CGRect, in ctx: CGContext) {
        let r = rect.integral.intersection(CGRect(origin: .zero, size: image.pixelSize))
        guard r.width >= 2, r.height >= 2, let sub = image.cropping(to: r) else { return }
        let block = max(8, min(r.width, r.height) / 8)
        let sw = max(1, Int(r.width / block)), sh = max(1, Int(r.height / block))
        guard let small = CGContext(
            data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        small.interpolationQuality = .medium
        small.draw(sub, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let tiny = small.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.drawUpright(tiny, in: r)
        ctx.restoreGState()
    }
}
