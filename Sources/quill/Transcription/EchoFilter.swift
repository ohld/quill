import Foundation

/// Removes the acoustic copy of system playback from the mic transcript.
///
/// A raw MacBook mic hears both the local speaker and whatever the laptop
/// speakers play. The system tap already contains that remote speech cleanly,
/// so keeping the mic copy produces two nearly simultaneous, differently
/// labelled versions of every remote sentence. Matching at word level keeps
/// the useful two-track role split without enabling Apple's playback-ducking
/// voice processing.
enum EchoFilter {
    // The real 71-minute call showed roughly 0.4 s of track drift and a 95th
    // percentile acoustic-copy lag near 0.6 s. Leave headroom for both.
    private static let overlapPadMs = 800
    private static let containmentThreshold = 0.65

    private struct Candidate {
        let segment: Transcript.Segment
        let words: [String]
    }

    static func dropEchoes(
        _ segments: [Transcript.Segment],
        micSpeaker: String,
        systemSpeaker: String
    ) -> [Transcript.Segment] {
        let microphoneSegments = segments.filter { belongs($0.speaker, to: micSpeaker) }
        let systemSegments = segments.filter { belongs($0.speaker, to: systemSpeaker) }
        let system = UtteranceGrouper.group(systemSegments)
            .map { Candidate(segment: $0, words: words($0.text)) }
        guard !system.isEmpty else { return segments }

        // Parakeet's response is often word-level. Compare
        // sentence-sized track-local context, then remove the original timed
        // word segments belonging to echoed mic utterances. Comparing each
        // one-word fragment independently cannot tolerate acoustic ASR errors.
        let echoedMicUtterances = UtteranceGrouper.group(microphoneSegments)
            .filter { isEcho($0, of: system) }

        return segments.filter { segment in
            guard belongs(segment.speaker, to: micSpeaker) else { return true }
            let midpoint = segment.start_ms + (segment.end_ms - segment.start_ms) / 2
            return !echoedMicUtterances.contains {
                midpoint >= $0.start_ms && midpoint <= $0.end_ms
            }
        }
    }

    private static func belongs(_ speaker: String, to trackSpeaker: String) -> Bool {
        speaker == trackSpeaker || speaker.hasPrefix("\(trackSpeaker) · ")
    }

    private static func isEcho(_ mic: Transcript.Segment, of system: [Candidate]) -> Bool {
        let overlapping = system.filter {
            min(mic.end_ms, $0.segment.end_ms + overlapPadMs)
                > max(mic.start_ms, $0.segment.start_ms - overlapPadMs)
        }
        guard !overlapping.isEmpty else { return false }

        let micWords = words(mic.text)
        // A punctuation-only fragment inside system speech is segmentation
        // residue. A real spoken fragment always contains a letter or number.
        guard !micWords.isEmpty else { return true }
        let systemWords = overlapping.flatMap(\.words)
        let contained = Double(subsequenceLength(of: micWords, in: systemWords))
            / Double(micWords.count)

        // Very short backchannels match by chance, so require an exact hit.
        return micWords.count <= 2
            ? contained == 1.0
            : contained >= containmentThreshold
    }

    /// Unicode-aware normalization: Russian, English, and mixed-language
    /// words compare directly while punctuation and repeated whitespace do
    /// not affect the match.
    private static func words(_ text: String) -> [String] {
        let normalized = text.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                return character
            }
            return " "
        }
        return String(normalized).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func subsequenceLength(of a: [String], in b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            current[0] = 0
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1] + 1
                    : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Turns word-level ASR output into sentence-sized blocks for transcript.md.
/// transcript.json keeps the filtered fine-grained timings for automation.
enum UtteranceGrouper {
    private static let maximumGapMs = 1_200
    private static let maximumDurationMs = 30_000
    private static let sentenceEndings: Set<Character> = [".", "!", "?", "…"]
    private static let noLeadingSpace: Set<Character> = [".", ",", "!", "?", ";", ":", "%", ")", "]", "}", "…"]

    static func group(_ segments: [Transcript.Segment]) -> [Transcript.Segment] {
        var grouped: [Transcript.Segment] = []
        for segment in segments.sorted(by: { $0.start_ms < $1.start_ms }) {
            guard let previous = grouped.last,
                  previous.speaker == segment.speaker,
                  segment.start_ms - previous.end_ms <= maximumGapMs,
                  segment.end_ms - previous.start_ms <= maximumDurationMs,
                  !endsSentence(previous.text)
            else {
                grouped.append(segment)
                continue
            }

            grouped[grouped.count - 1] = Transcript.Segment(
                speaker: previous.speaker,
                start_ms: previous.start_ms,
                end_ms: max(previous.end_ms, segment.end_ms),
                text: join(previous.text, segment.text)
            )
        }
        return grouped
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return false }
        return sentenceEndings.contains(last)
    }

    private static func join(_ left: String, _ right: String) -> String {
        let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        return rhs.first.map(noLeadingSpace.contains) == true
            ? lhs + rhs
            : lhs + " " + rhs
    }
}
