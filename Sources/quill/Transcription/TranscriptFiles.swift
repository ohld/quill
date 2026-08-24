import Foundation

/// Canonical locations for transcript artifacts and completed-session lookup.
/// `transcript.json` is written last, so its presence is the durable signal
/// that the adjacent readable transcript is ready to hand to another app.
enum TranscriptFiles {
    static func markdown(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("transcript.md")
    }

    static func completionMarker(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("transcript.json")
    }

    static func stableLatest(in recordingsRoot: URL) -> URL {
        recordingsRoot.appendingPathComponent("latest-transcript.md")
    }

    static func mostRecentCompletedTranscript(
        in recordingsRoot: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let session = entries
            .filter {
                fileManager.fileExists(atPath: markdown(in: $0).path)
                    && fileManager.fileExists(atPath: completionMarker(in: $0).path)
            }
            .max { $0.lastPathComponent < $1.lastPathComponent }
        return session.map(markdown(in:))
    }
}
