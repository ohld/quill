import Darwin
import Foundation
import XCTest
@testable import quill

@MainActor
final class SubprocessTranscriptionEngineTests: XCTestCase {
    func testRoundTripPreservesPathsAndSegmentsAndReusesWorkerAcrossTracks() async throws {
        try await withWorker { fixture in
            let beforePrepare = await fixture.engine.processIdentifier
            XCTAssertNil(beforePrepare)
            try await fixture.engine.prepare()
            let firstPID = try await fixture.requiredProcessIdentifier()
            try await fixture.engine.prepare()

            let paths = [
                fixture.root.appendingPathComponent("mic's \"quoted\"\nзапись.caf"),
                fixture.root.appendingPathComponent("system audio.caf"),
            ]
            for path in paths {
                let segments = try await fixture.engine.transcribe(path)
                XCTAssertEqual(segments.count, 2)
                guard segments.count == 2 else { return }
                XCTAssertEqual(segments[0].start, 1.25)
                XCTAssertEqual(segments[0].end, 2.75)
                XCTAssertEqual(segments[0].text, path.path)
                XCTAssertEqual(segments[0].speaker, "local voice")
                XCTAssertEqual(segments[1].start, 4)
                XCTAssertEqual(segments[1].end, 5.5)
                XCTAssertEqual(segments[1].text, "Привет\nследующая строка")
                XCTAssertNil(segments[1].speaker)
                let currentPID = await fixture.engine.processIdentifier
                XCTAssertEqual(currentPID, firstPID)
            }

            let events = try fixture.events()
            XCTAssertEqual(events.filter { $0.action == "launched" }.count, 1)
            XCTAssertEqual(
                events.filter { $0.action == "transcribe" }.compactMap(\.path),
                paths.map(\.path)
            )
            XCTAssertEqual(events.first?.arguments, ["_transcription-worker"])

            await fixture.engine.release()
            let afterRelease = await fixture.engine.processIdentifier
            XCTAssertNil(afterRelease)
            assertProcessExited(firstPID)
            await fixture.engine.release()
        }
    }

    func testReleaseAllowsFreshWorkerForNextQueueBatch() async throws {
        try await withWorker { fixture in
            try await fixture.engine.prepare()
            let firstPID = try await fixture.requiredProcessIdentifier()
            await fixture.engine.release()
            assertProcessExited(firstPID)

            try await fixture.engine.prepare()
            let secondPID = try await fixture.requiredProcessIdentifier()
            let segments = try await fixture.engine.transcribe(
                fixture.root.appendingPathComponent("next.caf")
            )
            XCTAssertEqual(segments.count, 2)
            XCTAssertEqual(try fixture.events().filter { $0.action == "launched" }.count, 2)

            await fixture.engine.release()
            assertProcessExited(secondPID)
        }
    }

    func testPreparationFailureTearsDownWorker() async throws {
        try await withWorker(mode: "prepare-failure") { fixture in
            do {
                try await fixture.engine.prepare()
                XCTFail("A worker preparation error must fail preparation")
            } catch {
                XCTAssertTrue(error is TranscriptionInfrastructureError)
                XCTAssertTrue(String(describing: error).contains("fixture preparation failed"))
            }
            let pid = try fixture.recordedPID()
            let afterFailure = await fixture.engine.processIdentifier
            XCTAssertNil(afterFailure)
            assertProcessExited(pid)
        }
    }

    func testBadAudioResponseKeepsWorkerAvailableForOtherTrack() async throws {
        try await withWorker(mode: "track-error") { fixture in
            try await fixture.engine.prepare()
            let pid = try await fixture.requiredProcessIdentifier()
            do {
                _ = try await fixture.engine.transcribe(fixture.root.appendingPathComponent("bad.caf"))
                XCTFail("Bad audio must report a track error")
            } catch {
                XCTAssertFalse(error is TranscriptionInfrastructureError)
            }
            let segments = try await fixture.engine.transcribe(fixture.root.appendingPathComponent("system.caf"))
            XCTAssertEqual(segments.count, 2)
            let currentPID = await fixture.engine.processIdentifier
            XCTAssertEqual(currentPID, pid)
        }
    }

    func testMalformedResponseFailsAndTearsDownWorker() async throws {
        try await assertTransportFailure(mode: "malformed-response")
    }

    func testEarlyWorkerExitFailsAndReapsWorker() async throws {
        try await assertTransportFailure(mode: "early-exit")
    }

    func testClosedWorkerInputFailsWithoutSendingSIGPIPEToParent() async throws {
        try await assertTransportFailure(mode: "closed-input")
    }

    private func assertTransportFailure(mode: String) async throws {
        try await withWorker(mode: mode) { fixture in
            try await fixture.engine.prepare()
            let pid = try await fixture.requiredProcessIdentifier()
            do {
                _ = try await fixture.engine.transcribe(
                    fixture.root.appendingPathComponent("mic.caf")
                )
                XCTFail("Broken worker transport must throw")
            } catch {
                // Reaching this assertion also verifies that a closed pipe
                // cannot kill the parent process with SIGPIPE.
                XCTAssertTrue(error is TranscriptionInfrastructureError)
            }
            let afterFailure = await fixture.engine.processIdentifier
            XCTAssertNil(afterFailure)
            assertProcessExited(pid)
        }
    }

    private func assertProcessExited(
        _ pid: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        errno = 0
        let result = Darwin.kill(pid, 0)
        let error = errno
        XCTAssertEqual(result, -1, "Worker must be gone before release returns", file: file, line: line)
        XCTAssertEqual(error, ESRCH, "Worker must have exited and been reaped", file: file, line: line)
    }

    private func withWorker(
        mode: String = "echo",
        _ body: (WorkerFixture) async throws -> Void
    ) async throws {
        let fixture = try WorkerFixture(mode: mode)
        do {
            try await body(fixture)
        } catch {
            await fixture.engine.release()
            fixture.remove()
            throw error
        }
        await fixture.engine.release()
        fixture.remove()
    }
}

private struct WorkerFixture {
    let root: URL
    let engine: SubprocessTranscriptionEngine

    init(mode: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill worker tests \(UUID().uuidString)",
            isDirectory: true
        )
        let executable = root.appendingPathComponent("fake worker")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let script = """
            #!/usr/bin/python3
            import json
            import os
            from pathlib import Path
            import sys
            import time

            root = Path(__file__).parent
            mode = "\(mode)"
            pid = os.getpid()
            (root / "worker.pid").write_text(str(pid))

            def record(event):
                with (root / "events.jsonl").open("a") as stream:
                    stream.write(json.dumps(dict(event, pid=pid)) + "\\n")

            def reply(value):
                print(json.dumps(value), flush=True)

            record({"action": "launched", "arguments": sys.argv[1:]})
            if sys.argv[1:] != ["_transcription-worker"]:
                sys.exit(18)

            for line in sys.stdin:
                request = json.loads(line)
                record(request)
                if request["action"] == "prepare":
                    if mode == "prepare-failure":
                        reply({"segments": [], "error": "fixture preparation failed"})
                    elif mode == "closed-input":
                        # Close before acknowledging prepare: the parent's next
                        # write deterministically targets a pipe with no reader.
                        os.close(0)
                        reply({"segments": []})
                        time.sleep(0.2)
                        sys.exit(0)
                    else:
                        reply({"segments": []})
                elif request["action"] == "transcribe":
                    if mode == "track-error" and request["path"].endswith("bad.caf"):
                        reply({"segments": [], "error": "unreadable audio"})
                        continue
                    if mode == "early-exit":
                        sys.exit(17)
                    if mode == "malformed-response":
                        print("not valid JSON", flush=True)
                        continue
                    reply({"segments": [
                        {"start": 1.25, "end": 2.75, "text": request["path"], "speaker": "local voice"},
                        {"start": 4, "end": 5.5, "text": "Привет\\nследующая строка"}
                    ]})
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        engine = SubprocessTranscriptionEngine(executableURL: executable)
    }

    func requiredProcessIdentifier() async throws -> Int32 {
        let pid = await engine.processIdentifier
        return try XCTUnwrap(pid)
    }

    func recordedPID() throws -> Int32 {
        let value = try String(contentsOf: root.appendingPathComponent("worker.pid"), encoding: .utf8)
        return try XCTUnwrap(Int32(value))
    }

    func events() throws -> [Event] {
        let data = try Data(contentsOf: root.appendingPathComponent("events.jsonl"))
        return try data.split(separator: 10).map {
            try JSONDecoder().decode(Event.self, from: Data($0))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    struct Event: Decodable {
        let action: String
        let path: String?
        let arguments: [String]?
    }
}
