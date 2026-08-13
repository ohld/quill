import AppKit
import XCTest
@testable import quill

final class TranscriptionEngineTests: XCTestCase {
    @MainActor
    func testTrayPositionIsSeededOnceButPreservesUserOrdering() {
        let suite = "quill-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        MenuBarController.seedPreferredPosition(defaults: defaults)
        XCTAssertEqual(
            defaults.integer(forKey: MenuBarController.preferredPositionKey),
            MenuBarController.preferredPosition
        )

        defaults.set(333, forKey: MenuBarController.preferredPositionKey)
        MenuBarController.seedPreferredPosition(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: MenuBarController.preferredPositionKey), 333)
    }

    @MainActor
    func testRecordingIconIsPrecoloredInsteadOfTemplateTinted() {
        XCTAssertEqual(MenuBarController.statusImage(recording: false)?.isTemplate, true)
        let image = MenuBarController.statusImage(recording: true)
        XCTAssertEqual(image?.isTemplate, false)

        guard
            let data = image?.tiffRepresentation,
            let pixels = NSBitmapImageRep(data: data)
        else { return XCTFail("recording icon did not render") }
        var redPixels = 0
        for x in 0..<pixels.pixelsWide {
            for y in 0..<pixels.pixelsHigh {
                guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.alphaComponent > 0.2,
                   color.redComponent > 0.7,
                   color.greenComponent < 0.5,
                   color.blueComponent < 0.5 {
                    redPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(redPixels, 0)
    }

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
