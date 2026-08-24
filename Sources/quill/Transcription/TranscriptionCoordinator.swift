import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    /// Queue activity is independent from the result of any one session.
    /// A caller can render this as transient progress without trying to infer
    /// which session just completed when the queue becomes idle.
    enum Progress: Sendable, Equatable {
        case idle
        case transcribing(sessionDir: URL, queued: Int)
    }

    /// Exactly one outcome is published for every session removed from the
    /// queue, before the coordinator advances to the next session.
    enum Outcome: Sendable, Equatable {
        case succeeded(sessionDir: URL)
        case failed(sessionDir: URL, reason: String)
    }

    private var queue: [URL] = []
    private var pending: Set<URL> = []
    private var draining = false
    private let config: AppConfig
    private var engine: (any TranscriptionEngine)?
    private let engineFactory: @Sendable () -> any TranscriptionEngine
    private var progressHandler: (@Sendable (Progress) -> Void)?
    private var outcomeHandler: (@Sendable (Outcome) -> Void)?

    init(
        config: AppConfig,
        engineFactory: @escaping @Sendable () -> any TranscriptionEngine = { ParakeetEngine() }
    ) {
        self.config = config
        self.engineFactory = engineFactory
    }

    func setProgressHandler(_ handler: @escaping @Sendable (Progress) -> Void) {
        progressHandler = handler
    }

    func setOutcomeHandler(_ handler: @escaping @Sendable (Outcome) -> Void) {
        outcomeHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard config.transcriptionEnabled else {
            runHook(for: sessionDir)
            return
        }
        appendIfNeeded(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard config.transcriptionEnabled else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var resumed = 0
        for dir in pending {
            if appendIfNeeded(dir) {
                resumed += 1
            }
        }
        if resumed > 0 {
            FileHandle.standardError.write(Data(
                "resuming \(resumed) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while true {
            while !queue.isEmpty {
                let dir = queue.removeFirst()
                publishProgress(.transcribing(sessionDir: dir, queued: queue.count))
                do {
                    try await transcribe(dir)
                    runHook(for: dir)
                    publishOutcome(.succeeded(sessionDir: dir))
                } catch {
                    let reason = String(describing: error)
                    log(dir, "transcription failed: \(reason)")
                    publishOutcome(.failed(sessionDir: dir, reason: reason))
                }
                pending.remove(dir)
            }

            await engine?.release()
            engine = nil

            // The actor is re-entrant while release() awaits. If another
            // session arrived, keep draining without briefly reporting idle.
            guard queue.isEmpty else { continue }
            draining = false
            publishProgress(.idle)
            return
        }
    }

    @discardableResult
    private func appendIfNeeded(_ sessionDir: URL) -> Bool {
        let dir = sessionDir.standardizedFileURL
        guard pending.insert(dir).inserted else { return false }
        queue.append(dir)
        return true
    }

    private func transcribe(_ dir: URL) async throws {
        let metadata = try RecordingMetadata.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        var successfulTracks = 0
        for track in metadata.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
                successfulTracks += 1
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let speaker = config.speakerName(for: track.kind)
            let offset = TimeInterval(track.offsetMilliseconds) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: $0.speaker.map { "\(speaker) · \($0)" } ?? speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        guard successfulTracks > 0 else {
            throw TranscriptionFailure.allTracksFailed
        }
        merged.sort { $0.start_ms < $1.start_ms }

        if config.transcriptEchoFilter {
            let before = merged.count
            merged = EchoFilter.dropEchoes(
                merged,
                micSpeaker: config.speakerNames.mic,
                systemSpeaker: config.speakerNames.system
            )
            if merged.count != before {
                log(
                    dir,
                    "echo filter dropped \(before - merged.count) mic segment(s) duplicating system audio"
                )
            }
        }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        let utterances = UtteranceGrouper.group(merged).count
        log(dir, "done — \(merged.count) segments, \(utterances) readable utterances")
    }

    private func preparedEngine() async throws -> any TranscriptionEngine {
        if let engine { return engine }
        let engine = engineFactory()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    private enum TranscriptionFailure: Error, CustomStringConvertible {
        case allTracksFailed

        var description: String {
            "all available audio tracks failed; leaving the session pending for retry"
        }
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = config.onStop else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publishProgress(_ progress: Progress) {
        progressHandler?(progress)
    }

    private func publishOutcome(_ outcome: Outcome) {
        outcomeHandler?(outcome)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Write the readable transcript, update the stable latest-transcript.md,
    /// then write transcript.json last as the completion marker. Every write
    /// is atomic, so resumePending never mistakes a half-finished job for done.
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let markdown = Data(rendered(title: dir.lastPathComponent).utf8)
        try markdown.write(
            to: TranscriptFiles.markdown(in: dir),
            options: .atomic
        )
        try markdown.write(
            to: TranscriptFiles.stableLatest(in: dir.deletingLastPathComponent()),
            options: .atomic
        )
        try encoder.encode(self).write(
            to: TranscriptFiles.completionMarker(in: dir),
            options: .atomic
        )
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in UtteranceGrouper.group(segments) {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
