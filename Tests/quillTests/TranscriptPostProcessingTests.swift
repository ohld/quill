import XCTest
@testable import quill

final class TranscriptPostProcessingTests: XCTestCase {
    func testRussianMicEchoIsDroppedButLocalSpeechRemains() {
        let segments = [
            segment("Call", 0, 900, "Привет,"),
            segment("Dan", 80, 980, "привет!"),
            segment("Call", 1_000, 1_700, "как дела?"),
            segment("Dan", 1_050, 1_750, "Как дела?"),
            segment("Dan", 2_200, 3_000, "Я готов начинать."),
        ]

        let filtered = EchoFilter.dropEchoes(
            segments,
            micSpeaker: "Dan",
            systemSpeaker: "Call"
        )

        XCTAssertEqual(filtered.map(\.text), ["Привет,", "как дела?", "Я готов начинать."])
        XCTAssertEqual(filtered.map(\.speaker), ["Call", "Call", "Dan"])
    }

    func testDifferentOverlappingMicSpeechIsPreserved() {
        let segments = [
            segment("Call", 0, 1_000, "Нужно обсудить бюджет."),
            segment("Dan", 100, 900, "Одну секунду."),
        ]

        XCTAssertEqual(
            EchoFilter.dropEchoes(segments, micSpeaker: "Dan", systemSpeaker: "Call").count,
            2
        )
    }

    func testDiarizedSystemSpeakerStillMatchesTrackPrefix() {
        let segments = [
            segment("Call · Speaker 1", 0, 1_000, "Hello there."),
            segment("Dan", 40, 1_040, "hello there"),
        ]

        let filtered = EchoFilter.dropEchoes(
            segments,
            micSpeaker: "Dan",
            systemSpeaker: "Call"
        )
        XCTAssertEqual(filtered.map(\.speaker), ["Call · Speaker 1"])
    }

    func testWordLevelAcousticErrorsAreFilteredUsingUtteranceContext() {
        let segments = [
            segment("Call", 0, 200, "Самый"),
            // The room copy produced one acoustic ASR error. Word-by-word
            // filtering would leave it as a bogus Dan interjection; sentence
            // context still identifies the whole utterance as system echo.
            segment("Dan", 180, 380, "там"),
            segment("Call", 210, 500, "элементарный"),
            segment("Dan", 390, 600, "элементарный"),
            segment("Call", 510, 800, "пример."),
            segment("Dan", 610, 900, "пример."),
            segment("Dan", 2_000, 2_500, "Мой ответ."),
        ]

        let filtered = EchoFilter.dropEchoes(
            segments,
            micSpeaker: "Dan",
            systemSpeaker: "Call"
        )

        XCTAssertEqual(
            filtered.filter { $0.speaker == "Dan" }.map(\.text),
            ["Мой ответ."]
        )
    }

    func testPunctuationOnlyMicResidueIsDroppedDuringSystemSpeech() {
        let segments = [
            segment("Call", 0, 1_000, "Продолжаем разговор"),
            segment("Dan", 200, 300, "...?!"),
        ]

        let filtered = EchoFilter.dropEchoes(
            segments,
            micSpeaker: "Dan",
            systemSpeaker: "Call"
        )

        XCTAssertEqual(filtered.map(\.speaker), ["Call"])
    }

    func testVeryShortMicPhraseRequiresCompleteMatchToBeAnEcho() {
        let segments = [
            segment("Call", 0, 1_000, "да конечно"),
            segment("Dan", 100, 900, "да нет"),
        ]

        let filtered = EchoFilter.dropEchoes(
            segments,
            micSpeaker: "Dan",
            systemSpeaker: "Call"
        )

        XCTAssertEqual(filtered.count, 2)
    }

    func testNoSystemTrackLeavesMicSegmentsUntouched() {
        let segments = [
            segment("Dan", 0, 100, "..."),
            segment("Dan", 200, 500, "Только микрофон"),
        ]

        XCTAssertEqual(
            EchoFilter.dropEchoes(
                segments,
                micSpeaker: "Dan",
                systemSpeaker: "Call"
            ).map(\.text),
            segments.map(\.text)
        )
    }

    func testWordSegmentsBecomeReadableUtterances() {
        let segments = [
            segment("Dan", 0, 100, "Ну,"),
            segment("Dan", 110, 300, "давай"),
            segment("Dan", 310, 600, "начнем."),
            segment("Dan", 800, 1_100, "Новая"),
            segment("Dan", 1_110, 1_400, "фраза!"),
            segment("Call", 1_500, 1_900, "Да."),
        ]

        let grouped = UtteranceGrouper.group(segments)

        XCTAssertEqual(grouped.map(\.text), ["Ну, давай начнем.", "Новая фраза!", "Да."])
        XCTAssertEqual(grouped.map(\.speaker), ["Dan", "Dan", "Call"])
        XCTAssertEqual(grouped[0].start_ms, 0)
        XCTAssertEqual(grouped[0].end_ms, 600)
    }

    func testUtteranceGapBoundaryMergesAtLimitAndSplitsBeyondIt() {
        let segments = [
            segment("Dan", 0, 100, "one"),
            segment("Dan", 1_300, 1_400, "two"),
            segment("Dan", 2_601, 2_700, "three"),
        ]

        let grouped = UtteranceGrouper.group(segments)

        XCTAssertEqual(grouped.map(\.text), ["one two", "three"])
    }

    func testEmptyTokensDoNotIntroduceSpacesOrLoseTiming() {
        let segments = [
            segment("Dan", 0, 100, "   "),
            segment("Dan", 110, 200, "Привет"),
            segment("Dan", 210, 300, " \n "),
            segment("Dan", 310, 400, "!"),
        ]

        let grouped = UtteranceGrouper.group(segments)

        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].text, "Привет!")
        XCTAssertEqual(grouped[0].start_ms, 0)
        XCTAssertEqual(grouped[0].end_ms, 400)
    }

    func testTranscriptWritesStableLatestFileAndCompletionMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-test-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("2026.08.12-1535", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = Transcript(
            engine: "test",
            model: "multilingual",
            created_at: "2026-08-12T00:00:00Z",
            segments: [segment("Dan", 0, 1_000, "Готово.")]
        )
        try transcript.write(to: session)

        let sessionMarkdown = try Data(
            contentsOf: session.appendingPathComponent("transcript.md")
        )
        let latestMarkdown = try Data(
            contentsOf: root.appendingPathComponent("latest-transcript.md")
        )
        XCTAssertEqual(latestMarkdown, sessionMarkdown)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: session.appendingPathComponent("transcript.json").path
        ))
    }

    func testMostRecentCompletedTranscriptReturnsSessionFileNotStableAlias() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-test-\(UUID().uuidString)", isDirectory: true)
        let older = root.appendingPathComponent("2026.08.12-1535", isDirectory: true)
        let newest = root.appendingPathComponent("2026.08.12-1600", isDirectory: true)
        let incomplete = root.appendingPathComponent("2026.08.12-1700", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = Transcript(
            engine: "test",
            model: "multilingual",
            created_at: "2026-08-12T00:00:00Z",
            segments: [segment("Dan", 0, 1_000, "Готово.")]
        )
        try transcript.write(to: older)
        try transcript.write(to: newest)
        try Data("not complete".utf8).write(to: TranscriptFiles.markdown(in: incomplete))

        let target = TranscriptFiles.mostRecentCompletedTranscript(in: root)

        XCTAssertEqual(
            target?.resolvingSymlinksInPath(),
            TranscriptFiles.markdown(in: newest).resolvingSymlinksInPath()
        )
        XCTAssertNotEqual(target, TranscriptFiles.stableLatest(in: root))
    }

    private func segment(
        _ speaker: String,
        _ start: Int,
        _ end: Int,
        _ text: String
    ) -> Transcript.Segment {
        Transcript.Segment(speaker: speaker, start_ms: start, end_ms: end, text: text)
    }
}
