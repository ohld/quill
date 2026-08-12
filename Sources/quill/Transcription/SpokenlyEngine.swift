import Foundation

/// Multilingual transcription through the official Spokenly CLI installed by
/// Spokenly.app. Quill keeps doing the part it is best at (loss-tolerant mic +
/// system recording); Spokenly supplies the user's selected local model and
/// optional diarization.
actor SpokenlyEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case cliNotFound
        case conversionFailed(String)
        case transcriptionFailed(String)
        case malformedResponse(String)

        var description: String {
            switch self {
            case .cliNotFound:
                return "Spokenly CLI not found — install it in Spokenly → Settings → Advanced"
            case .conversionFailed(let message):
                return "audio conversion failed: \(message)"
            case .transcriptionFailed(let message):
                return "Spokenly transcription failed: \(message)"
            case .malformedResponse(let message):
                return "Spokenly returned malformed JSON: \(message)"
            }
        }
    }

    nonisolated let name = "spokenly"
    nonisolated let model = "spokenly-active-model"

    private struct Response: Decodable {
        struct Segment: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let speakerId: String?
        }

        let modelId: ModelIdentifier?
        let segments: [Segment]

        /// Spokenly versions have emitted both a plain model id and a model
        /// metadata object. Accept both so an app update cannot strand the
        /// filesystem queue with otherwise valid transcript JSON.
        enum ModelIdentifier: Decodable, CustomStringConvertible {
            case string(String)
            case object([String: JSONValue])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) {
                    self = .string(string)
                } else {
                    self = .object(try container.decode([String: JSONValue].self))
                }
            }

            var description: String {
                switch self {
                case .string(let value): return value
                case .object(let value):
                    for key in ["id", "modelId", "name"] {
                        if case .string(let text) = value[key] { return text }
                    }
                    return "Spokenly model"
                }
            }
        }

        enum JSONValue: Decodable {
            case string(String), number(Double), bool(Bool), object([String: JSONValue])
            case array([JSONValue]), null

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() { self = .null }
                else if let value = try? container.decode(String.self) { self = .string(value) }
                else if let value = try? container.decode(Double.self) { self = .number(value) }
                else if let value = try? container.decode(Bool.self) { self = .bool(value) }
                else if let value = try? container.decode([String: JSONValue].self) {
                    self = .object(value)
                } else {
                    self = .array(try container.decode([JSONValue].self))
                }
            }
        }
    }

    private struct CommandResult {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var errorText: String {
            String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private var cli: String?

    func prepare() async throws {
        guard cli == nil else { return }
        guard let path = Config.spokenlyCLIPath() else { throw EngineError.cliNotFound }

        // The CLI talks to Spokenly.app over localhost. `open` is idempotent
        // when the menu-bar app is already running and makes launch-at-login
        // ordering robust when it is not.
        let open = try run("/usr/bin/open", ["-gja", "Spokenly"])
        if open.status != 0 {
            throw EngineError.transcriptionFailed(open.errorText)
        }
        guard await waitUntilReady() else {
            throw EngineError.transcriptionFailed(
                "Spokenly.app did not open its local CLI service on port 51089"
            )
        }
        cli = path
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let cli else { throw EngineError.cliNotFound }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-spokenly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Spokenly accepts WAV but not CAF. CAF remains the right recording
        // container because an interrupted meeting still leaves playable data.
        let wav = scratch.appendingPathComponent("track.wav")
        let converted = try run(
            "/usr/bin/afconvert",
            ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "--mix", audio.path, wav.path]
        )
        guard converted.status == 0 else {
            throw EngineError.conversionFailed(converted.errorText)
        }

        var arguments = ["transcribe", wav.path, "--format", "json"]
        let isSystemTrack = audio.lastPathComponent == "system.caf"
        if isSystemTrack, Config.diarizeSystemAudio() {
            arguments.append("--speakers")
        }

        let result = try run(cli, arguments)
        guard result.status == 0 else {
            throw EngineError.transcriptionFailed(result.errorText)
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: result.stdout)
        } catch {
            let raw = String(data: result.stdout, encoding: .utf8) ?? "<non-UTF8 output>"
            throw EngineError.malformedResponse("\(error); output: \(raw.prefix(500))")
        }

        if let modelId = response.modelId {
            FileHandle.standardError.write(Data(
                "spokenly: \(audio.lastPathComponent) → \(modelId.description)\n".utf8
            ))
        }
        return response.segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                start: segment.start,
                end: segment.end,
                text: text,
                speaker: segment.speakerId
            )
        }
    }

    func release() async {
        cli = nil
    }

    private func waitUntilReady() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:51089") else { return false }
        for _ in 0..<40 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<500).contains(http.statusCode) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Capture command output in files rather than pipes: hour-long meeting
    /// transcripts can exceed a pipe buffer, and waiting before draining a
    /// full pipe would deadlock the transcription queue.
    private func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = stdoutHandle
        task.standardError = stderrHandle
        try task.run()
        task.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        return CommandResult(
            status: task.terminationStatus,
            stdout: try Data(contentsOf: stdoutURL),
            stderr: try Data(contentsOf: stderrURL)
        )
    }
}
