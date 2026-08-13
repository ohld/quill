import Foundation
import XCTest
@testable import quill

final class TranscriptNotificationControllerTests: XCTestCase {
    func testPresentationUsesReadableStartTimeAndTranscriptPreview() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("2026.08.13-1345-2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try RecordingMetadata(
            startedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-13T10:45:00Z")),
            endedAt: nil,
            durationSeconds: nil,
            tracks: []
        ).write(
            to: dir
        )
        let transcript = Transcript(
            engine: "parakeet",
            model: "v3",
            created_at: "2026-08-13T10:46:00Z",
            segments: [
                Transcript.Segment(
                    speaker: "Call",
                    start_ms: 0,
                    end_ms: 2_000,
                    text: "  Что, какой у нас сегодня план?\n"
                ),
            ]
        )
        try JSONEncoder().encode(transcript).write(
            to: dir.appendingPathComponent("transcript.json")
        )

        let presentation = TranscriptNotificationPresentation.load(
            from: dir,
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
        )

        XCTAssertEqual(presentation.subtitle, "Запись в 13:45")
        XCTAssertEqual(presentation.preview, "Что, какой у нас сегодня план?")
        XCTAssertFalse(presentation.subtitle.contains("2026.08.13-1345"))
    }

    func testPresentationFallsBackToTimeEncodedInOldSessionFolder() {
        let dir = URL(fileURLWithPath: "/tmp/2026.08.13-0917-2", isDirectory: true)

        let presentation = TranscriptNotificationPresentation.load(from: dir)

        XCTAssertEqual(presentation.subtitle, "Запись в 09:17")
        XCTAssertEqual(presentation.preview, "Транскрипт сохранён локально")
    }

    func testNotificationActionTargetsExactSessionDirectory() {
        let path = "/Users/test/Recordings/2026.08.13-1345"

        let target = TranscriptNotificationController.actionTarget(
            userInfo: ["sessionPath": path]
        )

        XCTAssertEqual(target?.path, path)
        XCTAssertNil(TranscriptNotificationController.actionTarget(userInfo: [:]))
    }
}
