import Foundation

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Sendable, Codable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Optional engine-provided diarization label. Track identity remains the
    /// fallback, so mic/system still gives free me-vs-them separation.
    let speaker: String?

    init(start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// An engine transport or process failure does not establish that a track is
/// bad. Leave its session pending instead of completing a partial transcript.
enum TranscriptionInfrastructureError: Error, CustomStringConvertible {
    case workerFailed(String)

    var description: String {
        switch self {
        case .workerFailed(let message): return message
        }
    }
}

/// A speech-to-text engine quill can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async
}
