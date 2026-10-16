import Foundation

/// `Snip mcp`: a Model Context Protocol server on stdin/stdout, so an AI app (Claude Code, Claude
/// Desktop, Gemini CLI, …) can list, watch and edit recordings with tools. Each tool is a thin
/// wrapper around `VideoTools`. Setup lines: docs/AI-EDITING.md.
///
/// Protocol: newline-delimited JSON-RPC 2.0. Only responses go to stdout; anything else goes to stderr.
@MainActor
enum MCPServer {
    static let protocolVersion = "2025-06-18"

    static func run() async -> Int32 {
        let lines = AsyncStream<String> { continuation in
            let reader = Thread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
            reader.start()
        }
        for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            await handle(line)
        }
        return 0
    }

    // MARK: JSON-RPC

    private static func handle(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"] as [String: Any]])
            return
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        // Notifications (no id) never get a reply.
        guard let id else { return }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            reply(id, [
                "protocolVersion": asked ?? protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "snip", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                "instructions": instructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                reply(id, ["content": try await call(name, arguments)])
            } catch {
                reply(id, ["content": [text(error.localizedDescription)], "isError": true])
            }
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"] as [String: Any]])
        }
    }

    private static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    // MARK: Tools

    private static let instructions = """
    Snip records the user's screen on macOS. These tools find recordings, let you look at them quickly \
    (video_contact_sheet shows many labelled frames in one image; video_frame shows one exact frame), and \
    edit them (video_edit trims and cuts; it saves into the file and the old version goes to the Trash). \
    Look before cutting: find the moments with contact sheets, narrow down with a sheet over a short stretch, \
    then call video_edit with dry_run first. All times are seconds in the video as it is now; after an edit, \
    times shift, so check video_info again. Speedrun recordings keep their timer and splits in step with cuts; \
    speedrun_get_log and speedrun_update_log re-time splits.
    """

    private static let path: [String: Any] = ["type": "string", "description": "The recording's .mp4 path (from list_recordings)"]
    private static let seconds: [String: Any] = ["type": "number", "description": "Seconds into the video"]
    private static let ranges: [String: Any] = [
        "type": "array",
        "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2] as [String: Any],
        "description": "Stretches as [start, end] in seconds",
    ]

    private static var tools: [[String: Any]] {
        [
            tool("list_recordings", "The user's screen recordings, newest first.",
                 ["limit": ["type": "integer", "description": "How many (default 20)"]], required: []),
            tool("video_info", "Length, size, frame rate, sound tracks, and speedrun files of a recording.",
                 ["path": path], required: ["path"]),
            tool("video_contact_sheet",
                 "One image of evenly spaced frames, each labelled with its time. Use it to watch a whole video (or a stretch, with from/to) at a glance; narrow the stretch to find exact moments.",
                 ["path": path, "from": seconds, "to": seconds,
                  "count": ["type": "integer", "description": "Frames (default 24, max 120)"],
                  "columns": ["type": "integer", "description": "Frames per row (default 6)"]],
                 required: ["path"]),
            tool("video_frame", "One exact frame of a recording.",
                 ["path": path, "time": seconds, "width": ["type": "integer", "description": "Pixels wide (default 960)"]],
                 required: ["path", "time"]),
            tool("video_edit",
                 "Trims and cuts a recording and saves it in place (the old version goes to the Trash). keep: keep only these stretches; cut: remove these stretches; trim_start/trim_end: drop everything before/after. Use dry_run: true first to check the result.",
                 ["path": path, "keep": ranges, "cut": ranges,
                  "trim_start": seconds, "trim_end": seconds,
                  "dry_run": ["type": "boolean", "description": "Report the result without saving"]],
                 required: ["path"]),
            tool("speedrun_get_log", "The speedrun log of a recording: runs, split times (seconds in the video), pauses. Format: docs/SPEEDRUN-AI.md.",
                 ["path": path], required: ["path"]),
            tool("speedrun_update_log",
                 "Replaces a recording's speedrun log (e.g. with corrected split times) and redraws the timer into the video.",
                 ["path": path, "log": ["type": "object", "description": "The whole log, as speedrun_get_log returned it, edited"]],
                 required: ["path", "log"]),
        ]
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    private static func call(_ name: String, _ args: [String: Any]) async throws -> [[String: Any]] {
        func video() throws -> URL {
            guard let p = args["path"] as? String else { throw VideoTools.ToolError("path is required") }
            return try VideoTools.resolve(p)
        }
        func number(_ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }
        func rangeList(_ key: String) throws -> [ClosedRange<Double>] {
            guard let list = args[key] as? [[Any]] else { return [] }
            return try list.map { pair in
                guard pair.count == 2, let a = (pair[0] as? NSNumber)?.doubleValue, let b = (pair[1] as? NSNumber)?.doubleValue, b > a else {
                    throw VideoTools.ToolError("\(key) needs [start, end] pairs with end after start")
                }
                return a...b
            }
        }

        switch name {
        case "list_recordings":
            return [text(json(VideoTools.list(limit: (args["limit"] as? NSNumber)?.intValue ?? 20)))]
        case "video_info":
            return [text(json(try await VideoTools.info(try video())))]
        case "video_contact_sheet":
            let sheet = try await VideoTools.contactSheet(try video(), from: number("from"), to: number("to"),
                                                          count: (args["count"] as? NSNumber)?.intValue ?? 24,
                                                          columns: (args["columns"] as? NSNumber)?.intValue ?? 6)
            return [image(sheet.jpeg), text("Frames at (seconds): " + sheet.times.map { String(format: "%.2f", $0) }.joined(separator: ", "))]
        case "video_frame":
            guard let t = number("time") else { throw VideoTools.ToolError("time is required") }
            return [image(try await VideoTools.frame(try video(), at: t, width: (args["width"] as? NSNumber)?.intValue ?? 960))]
        case "video_edit":
            var request = VideoTools.EditRequest()
            request.keep = try rangeList("keep")
            request.cut = try rangeList("cut")
            request.trimStart = number("trim_start")
            request.trimEnd = number("trim_end")
            request.dryRun = args["dry_run"] as? Bool ?? false
            return [text(json(try await VideoTools.edit(try video(), request)))]
        case "speedrun_get_log":
            let logURL = RunLog.url(for: try video())
            guard FileManager.default.fileExists(atPath: logURL.path) else { throw VideoTools.ToolError("this recording has no speedrun timer") }
            return [text(String(decoding: try Data(contentsOf: logURL), as: UTF8.self))]
        case "speedrun_update_log":
            let url = try video()
            guard let object = args["log"], JSONSerialization.isValidJSONObject(object) else { throw VideoTools.ToolError("log must be an object") }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let log = try decoder.decode(RunLog.self, from: try JSONSerialization.data(withJSONObject: object))
            let logURL = RunLog.url(for: url)
            try log.data().write(to: logURL, options: .atomic)
            try await SpeedrunRenderer.rerender(logURL: logURL, to: url) { _ in }
            return [text("Saved the log and redrew the timer into \(url.path).")]
        default:
            throw VideoTools.ToolError("unknown tool \(name)")
        }
    }

    private static func text(_ string: String) -> [String: Any] { ["type": "text", "text": string] }

    private static func image(_ jpeg: Data) -> [String: Any] {
        ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
