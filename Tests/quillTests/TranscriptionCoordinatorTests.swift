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

    func testResumePendingProcessesOnlyUnfinishedSessionsOldestFirst() async throws {
        let fixture = try Fixture(failingSessions: [])
        defer { fixture.remove() }
        _ = try fixture.session("2026.08.24-1100")
        let completed = try fixture.session("2026.08.24-1200")
        _ = try fixture.session("2026.08.24-1000")
        try Data("already done".utf8).write(
            to: completed.appendingPathComponent("transcript.json")
        )
        let unfinalized = fixture.root.appendingPathComponent(
            "2026.08.24-0900",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unfinalized,
            withIntermediateDirectories: true
        )
        try Data().write(to: unfinalized.appendingPathComponent("mic.caf"))

        await fixture.observe()
        await fixture.coordinator.resumePending(root: fixture.root)
        try await fixture.waitForOutcomes(2)

        XCTAssertEqual(
            fixture.outcomeSummary,
            ["succeeded:2026.08.24-1000", "succeeded:2026.08.24-1100"]
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: unfinalized.appendingPathComponent("transcript.json").path
        ))
    }

    func testEnqueueDuringResumedSessionDoesNotDuplicateIt() async throws {
        let fixture = try Fixture(failingSessions: [], delay: .milliseconds(100))
        defer { fixture.remove() }
        let session = try fixture.session("resumed")

        await fixture.observe()
        await fixture.coordinator.resumePending(root: fixture.root)
        try await fixture.waitForTranscribing("resumed")
        await fixture.coordinator.enqueue(session)
        try await fixture.waitForOutcomes(1)

        XCTAssertEqual(fixture.outcomeSummary, ["succeeded:resumed"])
        XCTAssertEqual(
            fixture.progressSummary.filter { $0 == "transcribing:resumed" }.count,
            1
        )
    }

    func testOneBadTrackStillProducesTranscriptFromTheOtherTrack() async throws {
        let fixture = try Fixture(
            failingSessions: [],
            failingFiles: ["mic.caf"]
        )
        defer { fixture.remove() }
        let session = try fixture.session("partial", tracks: [.mic, .system])

        await fixture.enqueue([session])
        try await fixture.waitForOutcomes(1)

        XCTAssertEqual(fixture.outcomeSummary, ["succeeded:partial"])
        let transcript = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: session.appendingPathComponent("transcript.json"))
        )
        XCTAssertEqual(transcript.segments.map(\.speaker), ["them"])
        XCTAssertTrue(
            try String(contentsOf: session.appendingPathComponent("transcribe.log"))
                .contains("skipping mic.caf")
        )
    }

    func testWorkerFailureAfterSuccessfulTrackLeavesSessionPendingAndContinuesQueue() async throws {
        let fixture = try Fixture(
            failingSessions: [],
            infrastructureFailingSessions: ["interrupted"]
        )
        defer { fixture.remove() }
        let interrupted = try fixture.session("interrupted", tracks: [.mic, .system])
        let next = try fixture.session("next", tracks: [.mic, .system])

        await fixture.enqueue([interrupted, next])
        try await fixture.waitForOutcomes(2)

        XCTAssertEqual(fixture.outcomeSummary, ["failed:interrupted", "succeeded:next"])
        XCTAssertEqual(fixture.progressSummary.last, "idle")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: TranscriptFiles.completionMarker(in: interrupted).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: TranscriptFiles.completionMarker(in: next).path
        ))
        let log = try String(contentsOf: interrupted.appendingPathComponent("transcribe.log"))
        XCTAssertTrue(log.contains("transcribing mic.caf"))
        XCTAssertTrue(log.contains("transcription failed: fixture worker exited"))
    }

    func testEnginePreparationStaysLazyWithoutPendingSessions() async throws {
        let lifetime = EngineLifetime()
        let fixture = try Fixture(failingSessions: [], lifetime: lifetime)
        defer { fixture.remove() }

        await fixture.observe()
        await fixture.coordinator.resumePending(root: fixture.root)

        XCTAssertEqual(lifetime.summary, [])
        XCTAssertEqual(fixture.progressSummary, [])
    }

    func testSuccessfulSessionWaitsForEngineReleaseBeforeIdle() async throws {
        try await assertReleaseBeforeIdle(fails: false)
    }

    func testAllTrackFailureWaitsForEngineReleaseBeforeIdle() async throws {
        try await assertReleaseBeforeIdle(fails: true)
    }

    func testSessionArrivingDuringReleaseUsesFreshEngineWithoutFalseIdle() async throws {
        let lifetime = EngineLifetime()
        let fixture = try Fixture(failingSessions: [], delay: .zero, lifetime: lifetime)
        defer { fixture.remove() }
        let first = try fixture.session("first")
        let second = try fixture.session("second")

        await fixture.enqueue([first])
        await fulfillment(of: [lifetime.releaseStarted], timeout: 3)
        await fixture.coordinator.enqueue(second)

        XCTAssertEqual(fixture.progressSummary, ["transcribing:first"])
        XCTAssertEqual(lifetime.summary, ["created:1", "prepared:1", "transcribed:1", "releasing:1"])

        await lifetime.releaseGate.open()
        await fulfillment(of: [lifetime.idle], timeout: 3)

        XCTAssertEqual(fixture.outcomeSummary, ["succeeded:first", "succeeded:second"])
        XCTAssertEqual(fixture.progressSummary, ["transcribing:first", "transcribing:second", "idle"])
        XCTAssertEqual(lifetime.summary, [
            "created:1", "prepared:1", "transcribed:1", "releasing:1", "released:1",
            "created:2", "prepared:2", "transcribed:2", "releasing:2", "released:2", "idle",
        ])
    }

    private func assertReleaseBeforeIdle(fails: Bool) async throws {
        let lifetime = EngineLifetime()
        let fixture = try Fixture(
            failingSessions: fails ? ["session"] : [],
            delay: .zero,
            lifetime: lifetime
        )
        defer { fixture.remove() }
        let session = try fixture.session("session")

        await fixture.enqueue([session])
        await fulfillment(of: [lifetime.releaseStarted], timeout: 3)

        XCTAssertEqual(fixture.outcomeSummary, [fails ? "failed:session" : "succeeded:session"])
        XCTAssertEqual(fixture.progressSummary, ["transcribing:session"])
        XCTAssertEqual(lifetime.summary, ["created:1", "prepared:1", "transcribed:1", "releasing:1"])

        await lifetime.releaseGate.open()
        await fulfillment(of: [lifetime.idle], timeout: 3)

        XCTAssertEqual(lifetime.summary, [
            "created:1", "prepared:1", "transcribed:1", "releasing:1", "released:1", "idle",
        ])
    }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let coordinator: TranscriptionCoordinator
    private let events = EventLog()
    private let lifetime: EngineLifetime?

    init(
        failingSessions: Set<String>,
        failingFiles: Set<String> = [],
        infrastructureFailingSessions: Set<String> = [],
        delay: Duration = .milliseconds(25),
        lifetime: EngineLifetime? = nil
    ) throws {
        self.lifetime = lifetime
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        coordinator = TranscriptionCoordinator(
            config: AppConfig(
                recordingsRoot: root,
                transcriptionEnabled: true,
                speakerNames: .init(mic: "me", system: "them"),
                micVoiceProcessing: false,
                transcriptEchoFilter: true,
                onStop: nil
            ),
            engineFactory: {
                FakeEngine(
                    failingSessions: failingSessions,
                    failingFiles: failingFiles,
                    infrastructureFailingSessions: infrastructureFailingSessions,
                    delay: delay,
                    lifetime: lifetime
                )
            }
        )
    }

    var outcomeSummary: [String] { events.outcomeSummary }
    var progressSummary: [String] { events.progressSummary }

    func session(
        _ name: String,
        tracks kinds: [RecordingMetadata.Track.Kind] = [.mic]
    ) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tracks = try kinds.map { kind -> RecordingMetadata.Track in
            let file = "\(kind.rawValue).caf"
            try Data().write(to: dir.appendingPathComponent(file))
            return .init(kind: kind, file: file, offsetMilliseconds: 0)
        }
        try RecordingMetadata(
            startedAt: nil,
            endedAt: nil,
            durationSeconds: nil,
            tracks: tracks
        ).write(to: dir)
        return dir
    }

    func observe() async {
        await coordinator.setProgressHandler { [events, lifetime] progress in
            events.record(progress)
            if progress == .idle {
                lifetime?.record("idle")
                lifetime?.idle.fulfill()
            }
        }
        await coordinator.setOutcomeHandler { [events] in events.record($0) }
    }

    func enqueue(_ sessions: [URL]) async {
        // Ensure handlers are installed before the first enqueue. The setter
        // calls and enqueue all serialize through the coordinator actor.
        await observe()
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
    private let failingFiles: Set<String>
    private let infrastructureFailingSessions: Set<String>
    private let delay: Duration
    private let lifetime: EngineLifetime?
    private let id: Int

    init(
        failingSessions: Set<String>,
        failingFiles: Set<String>,
        infrastructureFailingSessions: Set<String>,
        delay: Duration,
        lifetime: EngineLifetime?
    ) {
        self.failingSessions = failingSessions
        self.failingFiles = failingFiles
        self.infrastructureFailingSessions = infrastructureFailingSessions
        self.delay = delay
        self.lifetime = lifetime
        self.id = lifetime?.createEngine() ?? 0
    }

    func prepare() async throws {
        lifetime?.record("prepared:\(id)")
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        lifetime?.record("transcribed:\(id)")
        try await Task.sleep(for: delay)
        if audio.lastPathComponent == "system.caf",
           infrastructureFailingSessions.contains(audio.deletingLastPathComponent().lastPathComponent) {
            throw TranscriptionInfrastructureError.workerFailed("fixture worker exited")
        }
        if failingSessions.contains(audio.deletingLastPathComponent().lastPathComponent)
            || failingFiles.contains(audio.lastPathComponent) {
            throw FakeFailure()
        }
        return [TranscriptSegment(start: 0, end: 1, text: "Готово")]
    }

    func release() async {
        guard let lifetime else { return }
        lifetime.record("releasing:\(id)")
        if id == 1 {
            lifetime.releaseStarted.fulfill()
            await lifetime.releaseGate.wait()
        }
        lifetime.record("released:\(id)")
    }

    private struct FakeFailure: Error {}
}

/// One ordered log covers both engine lifetime and coordinator progress.
/// The first release pauses at an explicit gate so tests can enqueue work
/// inside the actor's re-entrant cleanup window without relying on timing.
private final class EngineLifetime: @unchecked Sendable {
    let releaseStarted = XCTestExpectation(description: "first engine release started")
    let idle = XCTestExpectation(description: "coordinator became idle")
    let releaseGate = ReleaseGate()
    private let lock = NSLock()
    private var nextID = 0
    private var events: [String] = []

    func createEngine() -> Int {
        lock.withLock {
            nextID += 1
            events.append("created:\(nextID)")
            return nextID
        }
    }

    func record(_ event: String) {
        lock.withLock { events.append(event) }
    }

    var summary: [String] { lock.withLock { events } }
}

private actor ReleaseGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
