import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization. Always stop cleanly so
/// AVAudioFile can finalize the AAC-in-CAF packet table.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let config: AppConfig
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    var micHasAudio: Bool { mic.firstBufferAt != nil }
    var systemHasAudio: Bool { system.firstBufferAt != nil }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(config: AppConfig) throws {
        self.config = config
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = config.recordingsRoot.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = config.recordingsRoot.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(
                writingTo: dir.appendingPathComponent("mic.caf"),
                voiceProcessing: config.micVoiceProcessing
            )
        } catch {
            system.stop()
            throw error
        }
    }

    /// Stop both tracks, then atomically publish meta.json as the finalized
    /// session marker. Audio is always closed even when metadata cannot be
    /// written; callers must surface the error and must not enqueue the
    /// incomplete session for transcription.
    func stop() throws {
        mic.stop()
        system.stop()

        let ended = Date()
        let metadata = RecordingMetadata.finalized(
            startedAt: startedAt,
            endedAt: ended,
            firstBufferAt: [
                .mic: mic.firstBufferAt ?? startedAt,
                .system: system.firstBufferAt ?? startedAt,
            ]
        )
        try metadata.write(to: dir)
    }
}
