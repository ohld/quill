import Foundation

/// Canonical schema for a finalized recording session. `meta.json` is also
/// the filesystem queue's completion marker, so it is written atomically only
/// after both audio tracks have been stopped.
struct RecordingMetadata: Equatable, Sendable {
    static let fileName = "meta.json"

    struct Track: Equatable, Sendable {
        enum Kind: String, CaseIterable, Codable, Sendable {
            case mic
            case system

            fileprivate var defaultFile: String {
                switch self {
                case .mic: "mic.caf"
                case .system: "system.caf"
                }
            }
        }

        let kind: Kind
        let file: String
        let offsetMilliseconds: Int
    }

    let startedAt: Date?
    let endedAt: Date?
    let durationSeconds: Int?
    let tracks: [Track]

    init(
        startedAt: Date?,
        endedAt: Date?,
        durationSeconds: Int?,
        tracks: [Track]
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.tracks = tracks
    }

    static func finalized(
        startedAt: Date,
        endedAt: Date,
        firstBufferAt: [Track.Kind: Date]
    ) -> Self {
        let starts = Track.Kind.allCases.map { firstBufferAt[$0] ?? startedAt }
        let earliest = starts.min() ?? startedAt
        let tracks = Track.Kind.allCases.map { kind in
            let trackStart = firstBufferAt[kind] ?? startedAt
            return Track(
                kind: kind,
                file: kind.defaultFile,
                offsetMilliseconds: max(
                    0,
                    Int(trackStart.timeIntervalSince(earliest) * 1_000)
                )
            )
        }
        return Self(
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: max(0, Int(endedAt.timeIntervalSince(startedAt))),
            tracks: tracks
        )
    }

    static func read(from sessionDirectory: URL) throws -> Self {
        let data = try Data(contentsOf: sessionDirectory.appendingPathComponent(fileName))
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func write(to sessionDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: sessionDirectory.appendingPathComponent(Self.fileName),
            options: .atomic
        )
    }
}

extension RecordingMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case started
        case ended
        case durationSeconds = "duration_seconds"
        case files
        case startOffsets = "start_offset_ms"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let startedAt = try Self.decodeDateIfPresent(for: .started, from: values)
        let endedAt = try Self.decodeDateIfPresent(for: .ended, from: values)
        let duration = try values.decodeIfPresent(Int.self, forKey: .durationSeconds)
            ?? Self.duration(from: startedAt, to: endedAt)

        let files = try values.decode([String: String].self, forKey: .files)
        // Early Quill sessions did not capture per-track offsets. Both tracks
        // began within milliseconds, so zero preserves their historic meaning.
        let offsets = try values.decodeIfPresent([String: Int].self, forKey: .startOffsets) ?? [:]
        let tracks = Track.Kind.allCases.compactMap { kind -> Track? in
            guard let file = files[kind.rawValue] else { return nil }
            return Track(
                kind: kind,
                file: file,
                offsetMilliseconds: max(0, offsets[kind.rawValue] ?? 0)
            )
        }
        self.init(
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            tracks: tracks
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try Self.encode(startedAt, for: .started, to: &values)
        try Self.encode(endedAt, for: .ended, to: &values)
        try values.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try values.encode(
            Dictionary(uniqueKeysWithValues: tracks.map { ($0.kind.rawValue, $0.file) }),
            forKey: .files
        )
        try values.encode(
            Dictionary(uniqueKeysWithValues: tracks.map {
                ($0.kind.rawValue, $0.offsetMilliseconds)
            }),
            forKey: .startOffsets
        )
    }

    private static func duration(from startedAt: Date?, to endedAt: Date?) -> Int? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, Int(endedAt.timeIntervalSince(startedAt)))
    }

    private static func decodeDateIfPresent(
        for key: CodingKeys,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date? {
        guard let value = try values.decodeIfPresent(String.self, forKey: key) else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: values,
                debugDescription: "Expected an ISO 8601 timestamp"
            )
        }
        return date
    }

    private static func encode(
        _ date: Date?,
        for key: CodingKeys,
        to values: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        guard let date else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try values.encode(formatter.string(from: date), forKey: key)
    }
}
