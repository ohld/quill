import Foundation
import XCTest
@testable import quill

final class RecordingMetadataTests: XCTestCase {
    func testFinalizedMetadataRoundTripsThroughCanonicalSchema() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-13T10:45:00Z")
        )
        let ended = started.addingTimeInterval(125)
        let metadata = RecordingMetadata.finalized(
            startedAt: started,
            endedAt: ended,
            firstBufferAt: [
                .mic: started.addingTimeInterval(0.25),
                .system: started,
            ]
        )

        try metadata.write(to: dir)

        XCTAssertEqual(try RecordingMetadata.read(from: dir), metadata)
        XCTAssertEqual(metadata.durationSeconds, 125)
        XCTAssertEqual(
            metadata.tracks,
            [
                .init(kind: .mic, file: "mic.caf", offsetMilliseconds: 250),
                .init(kind: .system, file: "system.caf", offsetMilliseconds: 0),
            ]
        )
    }

    func testLegacyMetadataDefaultsMissingTimesAndOffsets() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"files":{"mic":"mic.caf","system":"system.caf"}}"#
        try Data(json.utf8).write(
            to: dir.appendingPathComponent(RecordingMetadata.fileName)
        )

        let metadata = try RecordingMetadata.read(from: dir)

        XCTAssertNil(metadata.startedAt)
        XCTAssertNil(metadata.endedAt)
        XCTAssertNil(metadata.durationSeconds)
        XCTAssertEqual(
            metadata.tracks,
            [
                .init(kind: .mic, file: "mic.caf", offsetMilliseconds: 0),
                .init(kind: .system, file: "system.caf", offsetMilliseconds: 0),
            ]
        )
    }

    func testLegacyMetadataPreservesKnownFilesAndDefaultsMissingOffsets() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"files":{"mic":"legacy-mic.caf"}}"#
        try Data(json.utf8).write(
            to: dir.appendingPathComponent(RecordingMetadata.fileName)
        )

        let metadata = try RecordingMetadata.read(from: dir)

        XCTAssertEqual(
            metadata.tracks,
            [.init(kind: .mic, file: "legacy-mic.caf", offsetMilliseconds: 0)]
        )
    }

    func testRecordingSessionReportsMetadataFinalizationFailure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(config: AppConfig(
            recordingsRoot: root,
            transcriptionEnabled: true,
            speakerNames: .init(mic: "me", system: "them"),
            micVoiceProcessing: false,
            transcriptEchoFilter: true,
            onStop: nil
        ))
        let metadataURL = session.dir.appendingPathComponent(RecordingMetadata.fileName)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try session.stop())

        // Audio cleanup is idempotent: once the obstruction is removed, the
        // same stopped session can publish its completion marker successfully.
        try FileManager.default.removeItem(at: metadataURL)
        XCTAssertNoThrow(try session.stop())
        XCTAssertNoThrow(try RecordingMetadata.read(from: session.dir))
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-metadata-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
