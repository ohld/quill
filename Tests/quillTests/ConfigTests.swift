import Foundation
import XCTest
@testable import quill

final class ConfigTests: XCTestCase {
    func testLoadsOneTypedSnapshotAndIgnoresRemovedEngineKeys() throws {
        let fixture = try TemporaryConfig(
            """
            {
              "recordings_dir": "/tmp/quill-recordings",
              "transcription": {
                "enabled": false,
                "engine": "removed-external-engine",
                "external_cli": "/missing/external-cli"
              },
              "speaker_names": { "mic": "Dan", "system": "Call" },
              "mic_voice_processing": true,
              "transcript_echo_filter": false,
              "on_stop": "notify-me"
            }
            """
        )

        let config = Config.load(from: fixture.url)

        XCTAssertEqual(config.recordingsRoot.path, "/tmp/quill-recordings")
        XCTAssertFalse(config.transcriptionEnabled)
        XCTAssertEqual(config.speakerNames, .init(mic: "Dan", system: "Call"))
        XCTAssertTrue(config.micVoiceProcessing)
        XCTAssertFalse(config.transcriptEchoFilter)
        XCTAssertEqual(config.onStop, "notify-me")
    }

    func testCLIOverrideWinsAndMissingValuesUseLocalFirstDefaults() throws {
        let fixture = try TemporaryConfig("{ \"recordings_dir\": \"/tmp/from-file\" }")
        let config = Config.load(cliOverride: "/tmp/from-cli", from: fixture.url)

        XCTAssertEqual(config.recordingsRoot.path, "/tmp/from-cli")
        XCTAssertTrue(config.transcriptionEnabled)
        XCTAssertEqual(config.speakerNames, .init(mic: "me", system: "them"))
        XCTAssertFalse(config.micVoiceProcessing)
        XCTAssertTrue(config.transcriptEchoFilter)
        XCTAssertNil(config.onStop)
    }
}

private final class TemporaryConfig {
    let directory: URL
    let url: URL

    init(_ contents: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-config-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("config.json")
        try Data(contents.utf8).write(to: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
