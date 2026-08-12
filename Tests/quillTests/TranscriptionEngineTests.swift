import XCTest
@testable import quill

final class TranscriptionEngineTests: XCTestCase {
    func testTrackSpeakerIsOptional() {
        let segment = TranscriptSegment(start: 1, end: 2, text: "hello")
        XCTAssertNil(segment.speaker)
    }

    func testEngineSpeakerIsPreserved() {
        let segment = TranscriptSegment(
            start: 1,
            end: 2,
            text: "hello",
            speaker: "Speaker 1"
        )
        XCTAssertEqual(segment.speaker, "Speaker 1")
    }
}
