import Foundation

/// Downloads only uploader-provided YouTube captions. Automatic captions and translations
/// are intentionally excluded, so missing creator tracks remain an explicit error.
struct CreatorVideo: Equatable, Sendable {
    let id: String
    let url: URL

    static func parse(_ input: String) -> CreatorVideo? {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String

        if isValidID(candidate) {
            id = candidate
        } else {
            guard let url = URL(string: candidate),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme?.lowercased() == "https",
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  let host = parts.host?.lowercased()
            else { return nil }

            let path = parts.path.split(separator: "/").map(String.init)
            switch host {
            case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
                if path == ["watch"] {
                    guard let value = parts.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
                    id = value
                } else if path.count == 2 && ["shorts", "live", "embed"].contains(path[0]) {
                    id = path[1]
                } else {
                    return nil
                }
            case "youtu.be", "www.youtu.be":
                guard path.count == 1 else { return nil }
                id = path[0]
            default:
                return nil
            }
        }

        guard isValidID(id), let canonicalURL = URL(string: "https://www.youtube.com/watch?v=\(id)") else {
            return nil
        }
        return CreatorVideo(id: id, url: canonicalURL)
    }

    private static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
}

enum CreatorCaptionError: LocalizedError {
    case missingDownloader
    case noCreatorCaptions
    case downloadFailed(String)
    case invalidCaptionFile

    var errorDescription: String? {
        switch self {
        case .missingDownloader:
            return "Creator subtitles require yt-dlp. Install it with `brew install yt-dlp` and try again."
        case .noCreatorCaptions:
            return "This video has no creator-authored captions for the selected language. Automatic captions were not substituted."
        case let .downloadFailed(message):
            return message.isEmpty ? "The creator subtitle download failed." : "The subtitle download failed: \(message)"
        case .invalidCaptionFile:
            return "The creator captions could not be converted into a TXT transcript."
        }
    }
}

enum CreatorCaptionText {
    /// Text is derived from the original VTT; its timestamps and formatting are left
    /// untouched in the separately saved .vtt file.
    static func plainText(from vtt: String) -> String {
        var lines: [String] = []
        var insideCue = false
        for rawLine in vtt.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                insideCue = false
                continue
            }
            if line.contains("-->") {
                insideCue = true
                continue
            }
            guard insideCue else { continue }
            let untagged = line.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            let text = untagged
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(text) }
        }
        return lines.joined(separator: "\n")
    }
}

private final class CaptionProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func register(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

struct CreatorCaptionService {
    func download(
        video: CreatorVideo,
        languageCode: String,
        formats: Set<OutputFormat>,
        outputDirectory: URL
    ) async throws -> [URL] {
        let control = CaptionProcessControl()
        let worker = Task.detached(priority: .userInitiated) {
            try Self.downloadSynchronously(
                video: video,
                languageCode: languageCode,
                formats: formats,
                outputDirectory: outputDirectory,
                control: control
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            control.cancel()
            worker.cancel()
        }
    }

    private static func downloadSynchronously(
        video: CreatorVideo,
        languageCode: String,
        formats: Set<OutputFormat>,
        outputDirectory: URL,
        control: CaptionProcessControl
    ) throws -> [URL] {
        let fileManager = FileManager.default
        guard let executable = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            NSHomeDirectory() + "/.local/bin/yt-dlp",
        ].map(URL.init(fileURLWithPath:)).first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw CreatorCaptionError.missingDownloader
        }

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("creator-captions-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--quiet", "--no-playlist", "--skip-download",
            "--write-subs", "--no-write-auto-subs",
            "--sub-langs", languageCode == "auto" ? "all" : "^\(languageCode)(?:-|$)",
            "--sub-format", "vtt",
            "--paths", staging.path,
            "--output", "\(video.id).%(language)s.%(ext)s",
            video.url.absoluteString,
        ]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try control.register(process)
        try Task.checkCancellation()
        try process.run()
        if control.isCancelled && process.isRunning { process.terminate() }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()
        if control.isCancelled { throw CancellationError() }
        if process.terminationStatus != 0 {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CreatorCaptionError.downloadFailed(message)
        }

        let captionFiles = try fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension.lowercased() == "vtt" &&
            $0.lastPathComponent.hasPrefix(video.id + ".")
        }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        guard !captionFiles.isEmpty else { throw CreatorCaptionError.noCreatorCaptions }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for caption in captionFiles {
            try Task.checkCancellation()
            let filename = caption.lastPathComponent
            let language = String(filename.dropFirst(video.id.count + 1).dropLast(4))
            guard !language.isEmpty,
                  language.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
                  })
            else { continue }

            let stem = nextAvailableStem("\(video.id).\(language)", formats: formats, directory: outputDirectory)
            if formats.contains(.txt) {
                let source = try String(contentsOf: caption, encoding: .utf8)
                let text = CreatorCaptionText.plainText(from: source)
                guard !text.isEmpty else { throw CreatorCaptionError.invalidCaptionFile }
                let destination = outputDirectory.appendingPathComponent(stem + ".txt")
                try text.write(to: destination, atomically: true, encoding: .utf8)
                outputs.append(destination)
            }
            if formats.contains(.vtt) {
                let destination = outputDirectory.appendingPathComponent(stem + ".vtt")
                try fileManager.copyItem(at: caption, to: destination)
                outputs.append(destination)
            }
        }
        guard !outputs.isEmpty else { throw CreatorCaptionError.noCreatorCaptions }
        return outputs
    }

    private static func nextAvailableStem(
        _ stem: String,
        formats: Set<OutputFormat>,
        directory: URL
    ) -> String {
        let fileManager = FileManager.default
        var candidate = stem
        var index = 2
        while formats.contains(where: {
            fileManager.fileExists(atPath: directory.appendingPathComponent(candidate + "." + $0.rawValue).path)
        }) {
            candidate = "\(stem)-\(index)"
            index += 1
        }
        return candidate
    }
}
