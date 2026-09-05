import ArgumentParser
import Darwin
import Foundation

/// Core ML keeps substantial native allocations after its model objects are
/// released. A worker lives for one queue drain; exiting it returns that memory
/// to macOS while the tray and audio capture stay in the lightweight parent.
final class SubprocessTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "parakeet"
    let model = "parakeet-tdt-0.6b-v3-coreml"

    private let executableURL: URL?
    private let ioQueue = DispatchQueue(label: "quill.transcription-worker.io", qos: .userInitiated)
    // All mutable state and blocking process/pipe operations are confined to
    // ioQueue. Capturing self in each queued operation keeps deinit out of it.
    private var connection: WorkerConnection?
    private var prepared = false

    init(executableURL: URL? = Bundle.main.executableURL) {
        self.executableURL = executableURL
    }

    var processIdentifier: Int32? {
        get async {
            try? await onIOQueue { self.connection?.processIdentifier }
        }
    }

    func prepare() async throws {
        try await onIOQueue {
            do {
                _ = try self.preparedConnection()
                self.prepared = true
            } catch {
                self.prepared = false
                throw TranscriptionInfrastructureError.workerFailed(String(describing: error))
            }
        }
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        try await onIOQueue {
            // A worker crash must not poison later tracks/sessions already in
            // the queue: the coordinator holds this wrapper until it drains.
            let connection: WorkerConnection
            do {
                guard self.prepared else { throw WorkerError.notPrepared }
                connection = try self.preparedConnection()
            } catch {
                throw TranscriptionInfrastructureError.workerFailed(String(describing: error))
            }
            do {
                return try connection.request(.init(action: .transcribe, path: audio.path))
            } catch WorkerError.transcriptionFailed(let message) {
                // Empty or corrupt audio is a track error, not a broken worker.
                throw WorkerError.transcriptionFailed(message)
            } catch {
                self.connection = nil
                let status = connection.closeAndWait(terminate: true)
                if case WorkerError.closedOutput = error {
                    throw TranscriptionInfrastructureError.workerFailed(WorkerError.exited(status).description)
                }
                throw TranscriptionInfrastructureError.workerFailed(String(describing: error))
            }
        }
    }

    func release() async {
        try? await onIOQueue {
            self.prepared = false
            guard let connection = self.connection else { return }
            self.connection = nil
            let status = connection.closeAndWait(terminate: false)
            if status != 0 {
                workerLog("transcription worker exited during release with status \(status)")
            }
        }
    }

    deinit {
        // Normally release() already reaped the worker. If the owner goes away
        // early, terminate and reap it without blocking the caller/main thread.
        if let connection {
            ioQueue.async { _ = connection.closeAndWait(terminate: true) }
        }
    }

    private func preparedConnection() throws -> WorkerConnection {
        if let connection, connection.isRunning { return connection }
        if let connection {
            _ = connection.closeAndWait(terminate: false)
            self.connection = nil
        }
        guard let executableURL else { throw WorkerError.missingExecutable }
        let connection = try WorkerConnection(executableURL: executableURL)
        do {
            _ = try connection.request(.init(action: .prepare, path: nil))
            self.connection = connection
            return connection
        } catch {
            let status = connection.closeAndWait(terminate: true)
            if case WorkerError.closedOutput = error {
                throw WorkerError.exited(status)
            }
            throw error
        }
    }

    private func onIOQueue<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private enum WorkerError: Error, CustomStringConvertible {
    case notPrepared
    case missingExecutable
    case launch(String)
    case pipe(String)
    case invalidResponse(String)
    case closedOutput
    case exited(Int32)
    case transcriptionFailed(String)

    var description: String {
        switch self {
        case .notPrepared: return "transcription worker used before prepare()"
        case .missingExecutable: return "cannot locate quill executable for transcription worker"
        case .launch(let message): return "cannot launch transcription worker: \(message)"
        case .pipe(let message): return "transcription worker pipe failed: \(message)"
        case .invalidResponse(let message): return "invalid transcription worker response: \(message)"
        case .closedOutput: return "transcription worker closed its output unexpectedly"
        case .exited(let status): return "transcription worker exited unexpectedly with status \(status)"
        case .transcriptionFailed(let message): return message
        }
    }
}

private struct WorkerRequest: Codable {
    enum Action: String, Codable { case prepare, transcribe }
    let action: Action
    let path: String?
}

private struct WorkerResponse: Codable {
    let segments: [TranscriptSegment]
    let error: String?
}

private let workerDirectoryKey = "QUILL_TRANSCRIPTION_WORKER_DIRECTORY"
private let workerParentPIDKey = "QUILL_TRANSCRIPTION_WORKER_PARENT_PID"
private let workerDirectoryPrefix = "quill-transcription-worker-"
private let workerOwnerMarker = ".quill-worker-owner"

/// Confined to the parent's serial IO queue, including deferred destruction.
private final class WorkerConnection: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let exited = DispatchSemaphore(value: 0)
    private let temporaryDirectory: URL
    private var reader: JSONLineReader

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(executableURL: URL) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process = Process()
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            workerDirectoryPrefix + UUID().uuidString, isDirectory: true
        )
        reader = JSONLineReader(handle: output)
        process.executableURL = executableURL
        process.arguments = ["_transcription-worker"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [exited] _ in exited.signal() }
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporaryDirectory.path + "/"
        environment[workerDirectoryKey] = temporaryDirectory.path
        environment[workerParentPIDKey] = String(getpid())
        process.environment = environment

        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(String(getpid()).utf8).write(
                to: temporaryDirectory.appendingPathComponent(workerOwnerMarker)
            )
            // A dead child turns a write into EPIPE instead of killing the tray
            // with SIGPIPE. This flag is local to the descriptor, not a global
            // signal policy shared with capture or the rest of the application.
            guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw WorkerError.pipe(String(cString: strerror(errno)))
            }
            try process.run()
        } catch {
            for handle in [input, output, inputPipe.fileHandleForReading, outputPipe.fileHandleForWriting] {
                try? handle.close()
            }
            removeWorkerDirectory(temporaryDirectory)
            throw WorkerError.launch(String(describing: error))
        }
        // Keeping the child's pipe ends open in the parent would mask EOF and
        // prevent failure detection or graceful worker shutdown.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
    }

    func request(_ request: WorkerRequest) throws -> [TranscriptSegment] {
        do { try writeJSONLine(request, to: input) }
        catch { throw WorkerError.pipe(String(describing: error)) }
        guard let data = try reader.readLine() else { throw WorkerError.closedOutput }
        let response: WorkerResponse
        do { response = try JSONDecoder().decode(WorkerResponse.self, from: data) }
        catch { throw WorkerError.invalidResponse(String(describing: error)) }
        if let error = response.error { throw WorkerError.transcriptionFailed(error) }
        return response.segments
    }

    @discardableResult
    func closeAndWait(terminate: Bool) -> Int32 {
        try? input.close()
        if terminate, process.isRunning { process.terminate() }
        let grace: DispatchTimeInterval = .seconds(terminate ? 2 : 5)
        if process.isRunning, exited.wait(timeout: .now() + grace) == .timedOut {
            if !terminate, process.isRunning {
                process.terminate()
                _ = exited.wait(timeout: .now() + .seconds(2))
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.close()
        removeWorkerDirectory(temporaryDirectory)
        return process.terminationStatus
    }
}

/// Requests contain paths; responses contain text. Even a long meeting stays
/// well below this bound. Reject runaway stdout instead of growing tray RAM.
private let maximumJSONLineBytes = 16 * 1024 * 1024

private struct JSONLineReader {
    let handle: FileHandle
    private var buffered = Data()

    init(handle: FileHandle) { self.handle = handle }

    mutating func readLine() throws -> Data? {
        while true {
            if let newline = buffered.firstIndex(of: 0x0a) {
                guard buffered.distance(from: buffered.startIndex, to: newline) <= maximumJSONLineBytes else {
                    throw WorkerError.invalidResponse("JSON line exceeds 16 MiB")
                }
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                return line
            }
            guard buffered.count <= maximumJSONLineBytes else {
                throw WorkerError.invalidResponse("JSON line exceeds 16 MiB")
            }
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkerError.pipe(String(cString: strerror(errno)))
            }
            if count == 0 {
                guard buffered.isEmpty else {
                    throw WorkerError.invalidResponse("incomplete JSON line at EOF")
                }
                return nil
            }
            buffered.append(contentsOf: bytes.prefix(count))
        }
    }
}

private func writeJSONLine<T: Encodable>(_ value: T, to handle: FileHandle) throws {
    var data = try JSONEncoder().encode(value)
    guard data.count <= maximumJSONLineBytes else {
        throw WorkerError.invalidResponse("JSON line exceeds 16 MiB")
    }
    data.append(0x0a)
    try handle.write(contentsOf: data)
}

private func workerLog(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

private func removeWorkerDirectory(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch {
        // The worker and parent both clean up; an already-removed directory
        // is expected when a graceful exit won the race.
        if FileManager.default.fileExists(atPath: directory.path) {
            workerLog("cannot remove transcription worker temporary directory \(directory.path): \(error)")
        }
    }
}

/// A parent can exit without running Swift deinits (for example NSApp.terminate).
/// Check from a separate queue so a busy Core ML call cannot orphan the worker.
private final class WorkerLifetime: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private let directory: URL?

    init() {
        let environment = ProcessInfo.processInfo.environment
        let parentPID = environment[workerParentPIDKey].flatMap(Int32.init) ?? getppid()
        // Never clean up a general TMPDIR supplied by the shell. Only accept a
        // task-specific directory with our UUID name and matching owner marker.
        let candidate = environment[workerDirectoryKey].map { URL(fileURLWithPath: $0) }
        if let candidate,
           candidate.lastPathComponent.hasPrefix(workerDirectoryPrefix),
           UUID(uuidString: String(candidate.lastPathComponent.dropFirst(workerDirectoryPrefix.count))) != nil,
           let marker = try? String(
               contentsOf: candidate.appendingPathComponent(workerOwnerMarker), encoding: .utf8
           ), marker == String(parentPID) {
            directory = candidate
        } else {
            directory = nil
        }
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [directory] in
            guard getppid() != parentPID else { return }
            if let directory { removeWorkerDirectory(directory) }
            Darwin._exit(1)
        }
        timer.resume()
    }

    func finish() {
        timer.cancel()
        if let directory { removeWorkerDirectory(directory) }
    }
}

/// Private stdio service launched by SubprocessTranscriptionEngine. Keeping it
/// a synchronous ParsableCommand leaves the existing AppKit entry point alone.
struct TranscriptionWorker: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_transcription-worker",
        abstract: "Internal local transcription worker.",
        shouldDisplay: false
    )

    func run() throws {
        // Ignored signal dispositions can survive exec from the tray process.
        // The worker must remain terminable. Treat a closed parent output pipe
        // as a write error so the task-owned temporary directory is cleaned.
        for number in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { signal(number, SIG_DFL) }
        guard fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) != -1 else {
            throw WorkerError.pipe(String(cString: strerror(errno)))
        }
        let lifetime = WorkerLifetime()
        Task.detached(priority: .userInitiated) {
            let status = await Self.serve()
            lifetime.finish()
            Darwin.exit(status)
        }
        dispatchMain()
    }

    private static func serve() async -> Int32 {
        let engine = ParakeetEngine()
        var reader = JSONLineReader(handle: .standardInput)
        do {
            while let data = try reader.readLine() {
                let request = try JSONDecoder().decode(WorkerRequest.self, from: data)
                let response: WorkerResponse
                do {
                    switch request.action {
                    case .prepare:
                        try await engine.prepare()
                        response = .init(segments: [], error: nil)
                    case .transcribe:
                        guard let path = request.path, !path.isEmpty else {
                            throw WorkerError.invalidResponse("missing audio path")
                        }
                        let segments = try await engine.transcribe(URL(fileURLWithPath: path))
                        response = .init(segments: segments, error: nil)
                    }
                } catch {
                    response = .init(segments: [], error: String(describing: error))
                }
                try writeJSONLine(response, to: .standardOutput)
            }
            await engine.release()
            return 0
        } catch {
            workerLog("transcription worker failed: \(error)")
            await engine.release()
            return 1
        }
    }
}
