import Foundation

/// One split of a speedrun.
struct Segment: Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Time on the clock at this split in the personal best (nil: never reached or skipped).
    var pbSplit: TimeInterval?
    /// Fastest this segment has ever been run (the "gold").
    var bestSegment: TimeInterval?

    init(id: UUID = UUID(), name: String, pbSplit: TimeInterval? = nil, bestSegment: TimeInterval? = nil) {
        self.id = id
        self.name = name
        self.pbSplit = pbSplit
        self.bestSegment = bestSegment
    }
}

enum SplitsError: LocalizedError {
    case notLiveSplit
    var errorDescription: String? { "That file isn't a LiveSplit splits file (.lss)." }
}

/// A speedrun's splits, stored in LiveSplit's .lss format so files move freely between Snip and
/// LiveSplit. Writing keeps every part of the file Snip doesn't edit (icons, attempt history,
/// auto-splitter settings) exactly as it was.
struct Splits {
    var game: String
    var category: String
    var attempts: Int
    /// Where the clock starts; negative counts down before the run (LiveSplit's "Start timer at").
    var offset: TimeInterval
    var segments: [Segment]

    /// The parsed file and each segment's element, so a save edits them in place.
    private var document: XMLDocument?
    private var elements: [UUID: XMLElement] = [:]

    init(game: String, category: String, segments: [Segment], attempts: Int = 0, offset: TimeInterval = 0) {
        self.game = game
        self.category = category
        self.segments = segments
        self.attempts = attempts
        self.offset = offset
    }

    static let blank = Splits(game: "", category: "Any%", segments: [Segment(name: "Finish")])

    var pbTime: TimeInterval? { segments.last?.pbSplit }

    /// Total of every gold; nil until each segment has one.
    var sumOfBest: TimeInterval? {
        var sum: TimeInterval = 0
        for s in segments {
            guard let best = s.bestSegment else { return nil }
            sum += best
        }
        return segments.isEmpty ? nil : sum
    }

    /// The segment's length in the personal best, when both ends of it were split.
    func pbSegment(_ i: Int) -> TimeInterval? {
        guard let end = segments[i].pbSplit else { return nil }
        if i == 0 { return end }
        return segments[i - 1].pbSplit.map { end - $0 }
    }

    // MARK: LiveSplit .lss

    init(lss data: Data) throws {
        let doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        guard let root = doc.rootElement(), root.name == "Run" else { throw SplitsError.notLiveSplit }
        game = root.child("GameName")?.stringValue ?? ""
        category = root.child("CategoryName")?.stringValue ?? ""
        attempts = Int(root.child("AttemptCount")?.stringValue ?? "") ?? 0
        offset = LSSTime.parse(root.child("Offset")?.stringValue) ?? 0
        segments = []
        for element in root.child("Segments")?.elements(forName: "Segment") ?? [] {
            let pb = element.child("SplitTimes")?.elements(forName: "SplitTime")
                .first { $0.attribute(forName: "name")?.stringValue == "Personal Best" }
            let segment = Segment(
                name: element.child("Name")?.stringValue ?? "",
                pbSplit: LSSTime.parse(pb?.child("RealTime")?.stringValue),
                bestSegment: LSSTime.parse(element.child("BestSegmentTime")?.child("RealTime")?.stringValue)
            )
            segments.append(segment)
            elements[segment.id] = element
        }
        document = doc
    }

    func lssData() -> Data {
        let doc = (document?.copy() as? XMLDocument) ?? Splits.skeleton()
        guard let root = doc.rootElement() else { return Data() }
        root.setText("GameName", game)
        root.setText("CategoryName", category)
        root.setText("Offset", LSSTime.format(offset))
        root.setText("AttemptCount", String(attempts))

        // Segments are matched by identity, so renamed, reordered or new ones keep their history.
        let copies = Dictionary(uniqueKeysWithValues: elements.compactMap { id, original -> (UUID, XMLElement)? in
            guard let path = original.xPath, let copy = (try? doc.nodes(forXPath: path))?.first as? XMLElement else { return nil }
            return (id, copy)
        })
        let list = root.child("Segments") ?? root.appended(XMLElement(name: "Segments"))
        let children = segments.map { segment -> XMLElement in
            let element = copies[segment.id] ?? Splits.newSegmentElement()
            element.detach()
            element.setText("Name", segment.name)
            let pb = element.ensureChild("SplitTimes").splitTime(named: "Personal Best")
            pb.setText("RealTime", segment.pbSplit.map(LSSTime.format))
            element.ensureChild("BestSegmentTime").setText("RealTime", segment.bestSegment.map(LSSTime.format))
            return element
        }
        list.setChildren(children)
        return doc.xmlData(options: [.nodePrettyPrint])
    }

    private static func skeleton() -> XMLDocument {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Run version="1.7.0"><GameIcon /><GameName /><CategoryName /><Metadata><Run id="" />\
        <Platform usesEmulator="False"></Platform><Region></Region><Variables /></Metadata>\
        <Offset>00:00:00</Offset><AttemptCount>0</AttemptCount><AttemptHistory /><Segments />\
        <AutoSplitterSettings /></Run>
        """
        // A literal, known-good document: parsing it cannot fail.
        return try! XMLDocument(xmlString: xml)
    }

    private static func newSegmentElement() -> XMLElement {
        let segment = XMLElement(name: "Segment")
        for name in ["Name", "Icon", "SplitTimes", "BestSegmentTime", "SegmentHistory"] {
            segment.addChild(XMLElement(name: name))
        }
        return segment
    }
}

/// LiveSplit's time strings: "[-][d.]hh:mm:ss[.fffffff]".
enum LSSTime {
    static func parse(_ text: String?) -> TimeInterval? {
        guard var s = text?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var sign = 1.0
        if s.hasPrefix("-") { sign = -1; s.removeFirst() }
        var parts = s.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return nil }
        var days = 0.0
        if let dot = parts[0].firstIndex(of: ".") {
            days = Double(parts[0][..<dot]) ?? 0
            parts[0] = String(parts[0][parts[0].index(after: dot)...])
        }
        guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return sign * (days * 86_400 + h * 3_600 + m * 60 + sec)
    }

    static func format(_ t: TimeInterval) -> String {
        let ticks = Int64((abs(t) * 10_000_000).rounded()) // .NET ticks: 100 ns
        let totalSeconds = ticks / 10_000_000
        let fraction = ticks % 10_000_000
        let days = totalSeconds / 86_400
        let h = (totalSeconds / 3_600) % 24, m = (totalSeconds / 60) % 60, s = totalSeconds % 60
        let body = String(format: "%02lld:%02lld:%02lld.%07lld", h, m, s, fraction)
        return (t < 0 ? "-" : "") + (days > 0 ? "\(days)." : "") + body
    }
}

private extension XMLElement {
    func child(_ name: String) -> XMLElement? { elements(forName: name).first }

    func ensureChild(_ name: String) -> XMLElement { child(name) ?? appended(XMLElement(name: name)) }

    @discardableResult
    func appended(_ element: XMLElement) -> XMLElement {
        addChild(element)
        return element
    }

    /// Sets a child element's text, creating it if needed; nil removes the child.
    func setText(_ name: String, _ value: String?) {
        guard let value else {
            if let existing = child(name) { removeChild(at: existing.index) }
            return
        }
        ensureChild(name).stringValue = value
    }

    func splitTime(named name: String) -> XMLElement {
        if let existing = elements(forName: "SplitTime").first(where: { $0.attribute(forName: "name")?.stringValue == name }) {
            return existing
        }
        let element = XMLElement(name: "SplitTime")
        element.addAttribute(XMLNode.attribute(withName: "name", stringValue: name) as! XMLNode)
        return appended(element)
    }
}
