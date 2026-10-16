import Foundation

/// `Snip video …`: look at and edit recordings from a terminal or an AI agent. Guide: docs/AI-EDITING.md.
@MainActor
enum VideoCLI {
    static let usage = """
    Usage: snip video <command>

      list [--limit N]                Recordings, newest first
      info <video>                    Length, size, frame rate, sound, speedrun files (JSON)
      sheet <video> [--from T] [--to T] [--count N] [--columns N] [--out file.jpg]
                                      One image of N frames (default 24) across the video or a stretch,
                                      each labelled with its time. The fast way to "watch" a video.
      frame <video> <time> [--width N] [--out file.jpg]
                                      One exact frame
      edit <video> [--keep A-B ...] [--cut A-B ...] [--start T] [--end T] [--dry-run]
                                      Trim and cut. --keep keeps only those stretches, --cut removes
                                      stretches, --start/--end trim the ends. Saves into the video (the old
                                      one goes to the Trash); speedrun timers and splits follow the cut.

    Times: seconds (83.4) or minutes:seconds (1:23.4). Ranges: 1:20-1:35.
    All times are in the video as it is now. Use --dry-run to see the result before saving.
    """

    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else {
            print(usage)
            return 0
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "list":
                printJSON(VideoTools.list(limit: Int(value("--limit", in: rest) ?? "") ?? 20))
            case "info":
                printJSON(try await VideoTools.info(try video(rest)))
            case "sheet":
                let url = try video(rest)
                let sheet = try await VideoTools.contactSheet(
                    url,
                    from: try value("--from", in: rest).map(VideoTools.time),
                    to: try value("--to", in: rest).map(VideoTools.time),
                    count: Int(value("--count", in: rest) ?? "") ?? 24,
                    columns: Int(value("--columns", in: rest) ?? "") ?? 6
                )
                let out = output(rest, default: "\(url.deletingPathExtension().lastPathComponent) sheet.jpg")
                try sheet.jpeg.write(to: out)
                print(out.path)
                print("Frames at: " + sheet.times.map { VideoTime.format($0) }.joined(separator: ", "))
            case "frame":
                let url = try video(rest)
                guard rest.count >= 2 else { throw VideoTools.ToolError("frame needs a time") }
                let t = try VideoTools.time(rest[1])
                let jpeg = try await VideoTools.frame(url, at: t, width: Int(value("--width", in: rest) ?? "") ?? 960)
                let out = output(rest, default: "\(url.deletingPathExtension().lastPathComponent) at \(String(format: "%.2f", t)).jpg")
                try jpeg.write(to: out)
                print(out.path)
            case "edit":
                let url = try video(rest)
                var request = VideoTools.EditRequest()
                request.keep = try values("--keep", in: rest).map(VideoTools.range)
                request.cut = try values("--cut", in: rest).map(VideoTools.range)
                request.trimStart = try value("--start", in: rest).map(VideoTools.time)
                request.trimEnd = try value("--end", in: rest).map(VideoTools.time)
                request.dryRun = rest.contains("--dry-run")
                let result = try await VideoTools.edit(url, request) { message in
                    FileHandle.standardError.write(Data("\(message)\n".utf8))
                }
                printJSON(result)
            case "help", "--help", "-h":
                print(usage)
            default:
                throw VideoTools.ToolError("unknown command \"\(command)\"\n\n\(usage)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("snip video: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func video(_ args: [String]) throws -> URL {
        guard let path = args.first, !path.hasPrefix("--") else { throw VideoTools.ToolError("give the video's path") }
        return try VideoTools.resolve(path)
    }

    private static func value(_ flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    private static func values(_ flag: String, in args: [String]) -> [String] {
        args.indices.compactMap { args[$0] == flag && args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    private static func output(_ args: [String], default name: String) -> URL {
        if let out = value("--out", in: args) { return URL(fileURLWithPath: (out as NSString).expandingTildeInPath) }
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
    }
}
