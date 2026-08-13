import Foundation
import XCTest
@testable import quill

final class TranscriptionCoordinatorTests: XCTestCase {
    func testPublishesAnOutcomeForEachOfTwoSuccessfulSessions() async throws {
        let fixture = try Fixture(failingSessions: [])
        defer { fixture.remove() }
        let first = try fixture.session("first")
        let second = try fixture.session("second")

        await fixture.enqueue([first, second])
        try await fixture.waitForOutcomes(2)

        XCTAssertEqual(
            fixture.outcomeSummary,
            ["succeeded:first", "succeeded:second"]
        )
        XCTAssertEqual(fixture.progressSummary.last, "idle")
    }

    func testSuccessThenFailurePublishesBothOutcomes() async throws {
        let fixture = try Fixture(failingSessions: ["second"])
        defer { fixture.remove() }
        let first = try fixture.session("first")
        let second = try fixture.session("second")

        await fixture.enqueue([first, second])
        try await fixture.waitForOutcomes(2)

        XCTAssertEqual(
            fixture.outcomeSummary,
            ["succeeded:first", "failed:second"]
        )
        XCTAssertEqual(fixture.progressSummary.last, "idle")
    }

    func testFailureThenSuccessDoesNotLoseEitherOutcome() async throws {
        let fixture = try Fixture(failingSessions: ["first"])
        defer { fixture.remove() }
        let first = try fixture.session("first")
        let second = try fixture.session("second")

        await fixture.enqueue([first, second])
        try await fixture.waitForOutcomes(2)

        XCTAssertEqual(
            fixture.outcomeSummary,
            ["failed:first", "succeeded:second"]
        )
        XCTAssertEqual(fixture.progressSummary.last, "idle")
    }

    func testDuplicateActiveSessionIsIgnoredWhileNewWorkStillQueues() async throws {
        let fixture = try Fixture(failingSessions: [], delay: .milliseconds(100))
        defer { fixture.remove() }
        let first = try fixture.session("first")
        let second = try fixture.session("second")

        await fixture.enqueue([first])
        try await fixture.waitForTranscribing("first")
        await fixture.coordinator.enqueue(first)
        await fixture.coordinator.enqueue(second)
        try await fixture.waitForOutcomes(2)

        XCTAssertEqual(
            fixture.outcomeSummary,
            ["succeeded:first", "succeeded:second"]
        )
        XCTAssertEqual(
            fixture.progressSummary.filter { $0 == "transcribing:first" }.count,
            1
        )
        XCTAssertEqual(fixture.progressSummary.last, "idle")
    }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let coordinator: TranscriptionCoordinator
    private let events = EventLog()

    init(failingSessions: Set<String>, delay: Duration = .milliseconds(25)) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = FakeEngine(failingSessions: failingSessions, delay: delay)
        coordinator = TranscriptionCoordinator(
            config: AppConfig(
                recordingsRoot: root,
                transcriptionEnabled: true,
                speakerNames: .init(mic: "me", system: "them"),
                micVoiceProcessing: false,
                transcriptEchoFilter: true,
                onStop: nil
            ),
            engineFactory: { engine }
        )
    }

    var outcomeSummary: [String] { events.outcomeSummary }
    var progressSummary: [String] { events.progressSummary }

    func session(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        try RecordingMetadata(
            startedAt: nil,
            endedAt: nil,
            durationSeconds: nil,
            tracks: [.init(kind: .mic, file: "mic.caf", offsetMilliseconds: 0)]
        ).write(to: dir)
        return dir
    }

    func enqueue(_ sessions: [URL]) async {
        // Ensure handlers are installed before the first enqueue. The setter
        // calls and enqueue all serialize through the coordinator actor.
        await coordinator.setProgressHandler { [events] in events.record($0) }
        await coordinator.setOutcomeHandler { [events] in events.record($0) }
        for session in sessions {
            await coordinator.enqueue(session)
        }
    }

    func waitForOutcomes(_ count: Int) async throws {
        try await waitUntil {
            self.events.outcomeSummary.count == count
                && self.events.progressSummary.last == "idle"
        }
    }

    func waitForTranscribing(_ session: String) async throws {
        try await waitUntil {
            self.events.progressSummary.contains("transcribing:\(session)")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Timeout()
    }

    private struct Timeout: Error {}
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [TranscriptionCoordinator.Outcome] = []
    private var progress: [TranscriptionCoordinator.Progress] = []

    func record(_ outcome: TranscriptionCoordinator.Outcome) {
        lock.withLock { outcomes.append(outcome) }
    }

    func record(_ value: TranscriptionCoordinator.Progress) {
        lock.withLock { progress.append(value) }
    }

    var outcomeSummary: [String] {
        lock.withLock {
            outcomes.map {
                switch $0 {
                case .succeeded(let dir): "succeeded:\(dir.lastPathComponent)"
                case .failed(let dir, _): "failed:\(dir.lastPathComponent)"
                }
            }
        }
    }

    var progressSummary: [String] {
        lock.withLock {
            progress.map {
                switch $0 {
                case .idle: "idle"
                case .transcribing(let dir, _): "transcribing:\(dir.lastPathComponent)"
                }
            }
        }
    }
}

private final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "fake"
    let model = "test"
    private let failingSessions: Set<String>
    private let delay: Duration

    init(failingSessions: Set<String>, delay: Duration) {
        self.failingSessions = failingSessions
        self.delay = delay
    }

    func prepare() async throws {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        try await Task.sleep(for: delay)
        if failingSessions.contains(audio.deletingLastPathComponent().lastPathComponent) {
            throw FakeFailure()
        }
        return [TranscriptSegment(start: 0, end: 1, text: "Готово")]
    }

    func release() async {}

    private struct FakeFailure: Error {}
}
