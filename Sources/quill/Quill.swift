import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, RecordOnce.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

/// Scriptable one-shot recording, also useful for verifying permissions and
/// the complete recording pipeline without clicking the menu bar. The normal
/// launch agent picks the finished session up and transcribes it on restart.
struct RecordOnce: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record mic and system audio for a fixed duration, then exit."
    )

    @Option(name: .long, help: "Recording duration in seconds.")
    var seconds: Double = 10

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        guard seconds >= 1 else { throw ValidationError("--seconds must be at least 1") }
        let session = try RecordingSession(root: Config.resolveRoot(cliOverride: out))
        try session.start()
        FileHandle.standardError.write(Data(
            "● recording \(seconds)s → \(session.dir.path)\n".utf8
        ))
        Thread.sleep(forTimeInterval: seconds)
        session.stop()
        print(session.dir.path)
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    @Flag(name: .long, help: "Start recording as soon as the tray app launches.")
    var startRecording = false

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // The tray must stay available even when setup is incomplete. A hard
        // startup exit is invisible for a background-only app and gives the
        // user no way to fix permissions from the UI.
        let checks = DoctorReport.run(recordingsRoot: root)
        let startupProblem = DoctorReport.allOK(checks) ? nil : checks.compactMap { check in
            if case .fail(let message) = check.status {
                return "\(check.name): \(message)"
            }
            return nil
        }.joined(separator: " · ")
        if startupProblem != nil {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // SwiftPM command-line entry points do not have an application
        // delegate to complete AppKit launch for them. Finish launching before
        // creating the NSStatusItem so macOS reliably publishes it.
        app.finishLaunching()

        let controller = AppController(root: root)
        if let startupProblem {
            controller.showStartupProblem(startupProblem)
        }
        if startRecording {
            controller.startRecording()
        }

        let shutdownSignals = [SIGINT, SIGTERM, SIGHUP]
        let signalSources = shutdownSignals.map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                FileHandle.standardError.write(Data("\nshutting down cleanly\n".utf8))
                MainActor.assumeIsolated { controller.shutdown() }
            }
            source.resume()
            return source
        }

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        // Keep every signal source alive for the full AppKit run loop. This
        // lets launchd logout/update termination finalize AAC packet tables
        // just like the tray's Stop/Quit actions.
        withExtendedLifetime((signalSources, controller)) {
            app.run()
        }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let notifications = TranscriptNotificationController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var transcribingSessionName: String?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onOpenLatestTranscript = { [weak self] in self?.openLatestTranscript() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onOpenRecording = { [weak self] dir in self?.openRecording(dir) }
        Task { [notifications] in
            await notifications.requestAuthorizationIfNeeded()
        }
        menuBar.update(recording: false, elapsed: nil)
        menuBar.updateSources(recording: false, micActive: false, systemActive: false)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    func startRecording() {
        guard session == nil else { return }
        startSession()
    }

    func showStartupProblem(_ problem: String) {
        menuBar.updateTranscription("setup required · \(problem)")
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            menuBar.showMessage(
                title: "Не удалось начать запись",
                detail: "\(error)"
            )
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        menuBar.updateSources(recording: true, micActive: false, systemActive: false)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)
        menuBar.updateSources(recording: false, micActive: false, systemActive: false)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
            if let name = transcribingSessionName {
                transcribingSessionName = nil
                let dir = root.appendingPathComponent(name)
                Task { @MainActor [weak self, dir] in
                    guard let self else { return }
                    let nativeAccepted = await self.notifications.notifyTranscriptReady(
                        sessionDir: dir
                    )
                    if TranscriptCompletionRoute.resolve(
                        nativeNotificationAccepted: nativeAccepted
                    ) == .trayFallback {
                        self.menuBar.showCompletion(sessionDir: dir)
                    }
                }
            }
        case .transcribing(let name, let queued):
            transcribingSessionName = name
            let text = queued > 0
                ? "transcribing \(name) · \(queued) queued"
                : "transcribing \(name)"
            menuBar.updateTranscription(text)
        case .failed(let name):
            transcribingSessionName = nil
            menuBar.updateTranscription("transcription failed · \(name)")
            menuBar.showTranscriptionFailure(sessionName: name)
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
        menuBar.updateSources(
            recording: true,
            micActive: session.micHasAudio,
            systemActive: session.systemHasAudio
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private func openLatestTranscript() {
        let latest = root.appendingPathComponent("latest-transcript.md")
        guard FileManager.default.fileExists(atPath: latest.path) else {
            menuBar.showMessage(
                title: "Транскриптов пока нет",
                detail: "Сначала завершите хотя бы одну запись"
            )
            return
        }
        NSWorkspace.shared.open(latest)
    }

    private func openRecording(_ dir: URL) {
        let transcript = dir.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: transcript.path) {
            NSWorkspace.shared.activateFileViewerSelecting([transcript])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
