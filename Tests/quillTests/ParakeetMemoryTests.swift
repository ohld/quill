import AVFoundation
@preconcurrency import Darwin
import XCTest
@testable import quill

/// Opt-in real-model smoke test. Uses generated silence, never a personal call.
/// Run with QUILL_ASR_MEMORY_TEST=1 swift test --filter ParakeetMemoryTests.
final class ParakeetMemoryTests: XCTestCase {
    func testRealWorkerPreservesBothTrackRoles() async throws {
        guard ProcessInfo.processInfo.environment["QUILL_ASR_MEMORY_TEST"] == "1" else {
            throw XCTSkip("Opt-in: loads the local Parakeet model")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-speech-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("synthetic-call", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (track, speech) in [
            ("mic", "This is the microphone. We will finish the project tomorrow."),
            ("system", "This is the remote participant. Thank you for joining the meeting."),
        ] {
            let voice = Process()
            voice.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            voice.arguments = ["-o", session.appendingPathComponent("\(track).caf").path, speech]
            try voice.run()
            voice.waitUntilExit()
            XCTAssertEqual(voice.terminationStatus, 0)
        }
        try RecordingMetadata(
            startedAt: nil, endedAt: nil, durationSeconds: nil,
            tracks: [
                .init(kind: .mic, file: "mic.caf", offsetMilliseconds: 0),
                .init(kind: .system, file: "system.caf", offsetMilliseconds: 10_000),
            ]
        ).write(to: session)
        let executable = Bundle(for: ParakeetMemoryTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("quill")
        let coordinator = TranscriptionCoordinator(
            config: AppConfig(
                recordingsRoot: root, transcriptionEnabled: true,
                speakerNames: .init(mic: "me", system: "remote"),
                micVoiceProcessing: false, transcriptEchoFilter: true, onStop: nil
            ),
            engineFactory: { SubprocessTranscriptionEngine(executableURL: executable) }
        )
        let idle = expectation(description: "synthetic call transcribed and worker reaped")
        await coordinator.setProgressHandler { if $0 == .idle { idle.fulfill() } }
        await coordinator.enqueue(session)
        await fulfillment(of: [idle], timeout: 120)
        let transcript = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: TranscriptFiles.completionMarker(in: session))
        )
        XCTAssertEqual(Set(transcript.segments.map(\.speaker)), ["me", "remote"])
        XCTAssertTrue(transcript.segments.filter { $0.speaker == "remote" }.allSatisfy { $0.start_ms >= 10_000 })
        XCTAssertTrue(transcript.segments.allSatisfy { !$0.text.isEmpty })
        XCTAssertEqual(transcript.model, "parakeet-tdt-0.6b-v3-coreml")
    }

    func testMemoryReturnsAfterTranscription() async throws {
        guard ProcessInfo.processInfo.environment["QUILL_ASR_MEMORY_TEST"] == "1" else {
            throw XCTSkip("Opt-in: loads the local Parakeet model")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("silence.caf")
        let seconds = Int(ProcessInfo.processInfo.environment["QUILL_ASR_TEST_SECONDS"] ?? "60") ?? 60
        try Self.writeSilence(to: audio, seconds: seconds)
        let executable = Bundle(for: ParakeetMemoryTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("quill")
        let inProcess = ProcessInfo.processInfo.environment["QUILL_ASR_IN_PROCESS"] == "1"
        let baseline = try Self.footprint()
        print("ASR memory baseline: \(baseline / 1_048_576) MiB")
        for cycle in 1...2 {
            let start = ContinuousClock.now
            try await Task.detached { @Sendable [audio, cycle, executable, inProcess] in
                let engine: any TranscriptionEngine = inProcess
                    ? ParakeetEngine()
                    : SubprocessTranscriptionEngine(executableURL: executable)
                do {
                    try await engine.prepare()
                    print("ASR memory prepared \(cycle): \(try ParakeetMemoryTests.footprint() / 1_048_576) MiB")
                    _ = try await engine.transcribe(audio)
                    print("ASR memory transcribed \(cycle): \(try ParakeetMemoryTests.footprint() / 1_048_576) MiB")
                } catch {
                    await engine.release()
                    throw error
                }
                await engine.release()
            }.value
            try await Task.sleep(for: .seconds(2))
            let idle = try Self.footprint()
            print("ASR memory released \(cycle): \(idle / 1_048_576) MiB; elapsed: \(start.duration(to: .now))")
            // A model-sized allocation must not remain once the queue is idle.
            XCTAssertLessThan(idle - min(idle, baseline), 200 * 1_048_576)
        }
    }

    private static func writeSilence(to url: URL, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        for _ in 0..<seconds { try file.write(from: buffer) }
    }

    private static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(status))
        }
        return info.phys_footprint
    }
}
