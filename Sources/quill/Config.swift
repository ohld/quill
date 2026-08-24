import Foundation

/// Immutable configuration used for one process lifetime. Loading once keeps
/// a recording and its transcript internally consistent even if the file is
/// edited while work is in progress.
struct AppConfig: Sendable, Equatable {
    struct SpeakerNames: Sendable, Equatable {
        let mic: String
        let system: String
    }

    let recordingsRoot: URL
    let transcriptionEnabled: Bool
    let speakerNames: SpeakerNames
    let micVoiceProcessing: Bool
    let transcriptEchoFilter: Bool
    let onStop: String?

    func speakerName(for kind: RecordingMetadata.Track.Kind) -> String {
        switch kind {
        case .mic: speakerNames.mic
        case .system: speakerNames.system
        }
    }
}

enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    private struct FileConfig: Decodable {
        struct Transcription: Decodable {
            var enabled: Bool?
        }

        struct Speakers: Decodable {
            var mic: String?
            var system: String?
        }

        var recordingsDir: String?
        var transcription: Transcription?
        var speakerNames: Speakers?
        var micVoiceProcessing: Bool?
        var transcriptEchoFilter: Bool?
        var onStop: String?

        enum CodingKeys: String, CodingKey {
            case recordingsDir = "recordings_dir"
            case transcription
            case speakerNames = "speaker_names"
            case micVoiceProcessing = "mic_voice_processing"
            case transcriptEchoFilter = "transcript_echo_filter"
            case onStop = "on_stop"
        }
    }

    /// Load the user's JSON once. Unknown legacy engine keys are deliberately
    /// ignored by `Decodable`.
    static func load(
        cliOverride: String? = nil,
        from fileURL: URL = path,
        defaultRoot fallbackRoot: URL = defaultRoot
    ) -> AppConfig {
        let fileConfig: FileConfig?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                fileConfig = try JSONDecoder().decode(
                    FileConfig.self,
                    from: Data(contentsOf: fileURL)
                )
            } catch {
                warn("\(fileURL.path) is not valid configuration — using defaults (\(error))")
                fileConfig = nil
            }
        } else {
            fileConfig = nil
        }

        let configuredRoot = nonempty(fileConfig?.recordingsDir).map(expandedURL)
        let root = nonempty(cliOverride).map(expandedURL) ?? configuredRoot ?? fallbackRoot
        let speakers = fileConfig?.speakerNames

        return AppConfig(
            recordingsRoot: root,
            transcriptionEnabled: fileConfig?.transcription?.enabled ?? true,
            speakerNames: .init(
                mic: nonempty(speakers?.mic) ?? "me",
                system: nonempty(speakers?.system) ?? "them"
            ),
            micVoiceProcessing: fileConfig?.micVoiceProcessing ?? false,
            transcriptEchoFilter: fileConfig?.transcriptEchoFilter ?? true,
            onStop: nonempty(fileConfig?.onStop)
        )
    }

    private static func expandedURL(_ path: String) -> URL {
        URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }
}
