import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "parakeet",
///         "spokenly_cli": "/usr/local/bin/spokenly",
///         "diarize_system_audio": false
///       },
///       "speaker_names": { "mic": "me", "system": "them" },
///       "mic_voice_processing": true,
///       "transcript_echo_filter": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. FluidAudio Parakeet v3 is the safe default:
    /// multilingual, fully local, and independent of Spokenly UI state.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    /// Resolve the Spokenly CLI explicitly rather than relying only on PATH.
    /// LaunchAgents inherit a deliberately sparse PATH and would otherwise
    /// miss the standard /usr/local/bin symlink installed by Spokenly.app.
    static func spokenlyCLIPath() -> String? {
        if let configured = transcription()?["spokenly_cli"] as? String, !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        let candidates = [
            "/usr/local/bin/spokenly",
            "/opt/homebrew/bin/spokenly",
        ]
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return found
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("spokenly").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Spokenly's speaker diarization is useful on the system track, where a
    /// meeting can contain several remote participants. The mic track is
    /// already a clean, single-speaker recording and does not need it.
    static func diarizeSystemAudio() -> Bool {
        transcription()?["diarize_system_audio"] as? Bool ?? false
    }

    static func speakerName(for track: String) -> String {
        let names = load()?["speaker_names"] as? [String: String]
        return names?[track] ?? (track == "mic" ? "me" : "them")
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Drop mic words that duplicate overlapping system speech. This is the
    /// text-level fallback for raw mic capture through laptop speakers, where
    /// the far end is otherwise labelled as both participants.
    static func transcriptEchoFilter() -> Bool {
        load()?["transcript_echo_filter"] as? Bool ?? true
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
