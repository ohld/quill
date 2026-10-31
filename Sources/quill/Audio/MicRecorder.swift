@preconcurrency import AVFoundation
import Foundation

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With optional voice processing on, Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
///
/// AVAudioEngine stops for good when the input route changes mid-call (a
/// Bluetooth headset connects or drops, the default device switches, another
/// app reconfigures the mic). A watchdog restarts capture whenever no buffer
/// has arrived for a few seconds; `MicTrackWriter` resamples the new route to
/// the file's format and pads the gap so the track stays time-aligned.
/// `AVAudioEngine` invokes tap closures on its own realtime thread. Swift
/// cannot prove that relationship safe, so this type is `@unchecked
/// Sendable`; every mutable property shared with a tap is guarded by
/// `stateLock`. Lifecycle operations hold the lock throughout, while taps use
/// `try()` and drop a buffer rather than blocking the realtime thread.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    private let stateLock = NSLock()
    private var engine = AVAudioEngine()
    private var writer: MicTrackWriter?
    private var url: URL?
    private var recording = false
    private var voiceProcessing = false
    private var generation: UInt64 = 0
    private var capturedFirstBufferAt: Date?

    // Stall watchdog: restarts the engine when buffers stop arriving.
    private var watchdog: DispatchSourceTimer?
    private var lastBufferAt = Date()
    private var stallRestarts = 0

    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    var firstBufferAt: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return capturedFirstBufferAt
    }

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension).
    /// A clean stop is still required to finalize AAC packet metadata.
    func start(writingTo url: URL, voiceProcessing: Bool) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !recording else { return }

        generation &+= 1
        capturedFirstBufferAt = nil
        stallRestarts = 0
        self.url = url
        self.voiceProcessing = voiceProcessing
        do {
            try attach(generation: generation)
            recording = true
        } catch {
            writer = nil
            self.url = nil
            throw error
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.restartIfStalled() }
        timer.resume()
        watchdog = timer
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard recording else { return }

        recording = false
        generation &+= 1
        watchdog?.cancel()
        watchdog = nil
        // Finalize the file before touching the engine so a blocking
        // engine.stop() can't leave it unfinalized. No tap can be writing
        // here: an existing writer had to release the same lock before stop
        // acquired it, and new callbacks use try() and see recording == false.
        writer = nil
        url = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if capturedFirstBufferAt == nil {
            FileHandle.standardError.write(Data(
                "warning: mic delivered no audio this session — mic track is empty\n".utf8
            ))
        }
    }

    // MARK: -

    /// Build the engine graph and start capture, creating the AAC file on the
    /// first call. Called at start, after a stall, and (raw) if the voice
    /// processing liveness check trips. `stateLock` must be held by the caller.
    private func attach(generation: UInt64) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format for the Voice I/O boundary — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture taps the native route format
        // and the writer downmixes; speech models want one channel anyway.
        guard inputFormat.sampleRate > 0, let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        if writer == nil {
            do {
                writer = try MicTrackWriter(url: url!, sampleRate: monoFormat.sampleRate)
            } catch {
                throw RecorderError.fileCreationFailed(error)
            }
        }

        let tapFormat: AVAudioFormat
        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            tapFormat = monoFormat
        } else {
            tapFormat = inputFormat
        }
        let checkFrames = Int(monoFormat.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self, self.stateLock.try() else { return }
            defer { self.stateLock.unlock() }
            guard self.recording, self.generation == generation else { return }
            if voice, !self.checkLivenessLocked(buffer, checkFrames: checkFrames, generation: generation) {
                return
            }
            self.writeLocked(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error)
        }
        lastBufferAt = Date()

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(tapFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// `stateLock` must be held by the caller.
    private func writeLocked(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        let first = capturedFirstBufferAt ?? now
        capturedFirstBufferAt = first
        lastBufferAt = now
        stallRestarts = 0
        do {
            try writer?.write(buffer, elapsed: now.timeIntervalSince(first))
        } catch {
            FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
        }
    }

    /// Voice-processing path: tracks signal peak over the first second — an
    /// unsupported route (device pair, macOS AUVPAggregate defects) delivers
    /// callbacks full of digital zeros, and the only recovery is restarting
    /// raw. Returns false when the buffer must not be written.
    /// `stateLock` must be held by the caller.
    private func checkLivenessLocked(
        _ buffer: AVAudioPCMBuffer,
        checkFrames: Int,
        generation: UInt64
    ) -> Bool {
        guard !livenessSettled else { return true }
        let frames = Int(buffer.frameLength)
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<frames {
                livenessPeak = max(livenessPeak, abs(data[i]))
            }
        }
        livenessFrames += frames
        guard livenessFrames >= checkFrames else { return true }
        livenessSettled = true
        guard livenessPeak == 0 else { return true }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            guard self.recording, self.generation == generation else { return }
            self.voiceProcessing = false
            self.restartLocked(reason: "voice processing delivered silence — restarting mic raw")
        }
        return false
    }

    /// Watchdog tick (main queue). AVAudioEngine stops itself on a route or
    /// device configuration change and never resumes; no buffers for a few
    /// seconds means capture is dead, so rebuild it on the current route.
    /// Backs off while the route keeps delivering nothing.
    private func restartIfStalled() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard recording else { return }
        let stalled = Date().timeIntervalSince(lastBufferAt)
        let limit = min(3 * pow(2, Double(stallRestarts)), 60)
        guard stalled >= limit else { return }
        stallRestarts += 1
        restartLocked(reason: "mic delivered no audio for \(Int(stalled))s (route change?) — restarting capture")
    }

    /// Tear the engine down and attach again on the current default input,
    /// keeping the same file. `stateLock` must be held by the caller.
    private func restartLocked(reason: String) {
        FileHandle.standardError.write(Data("warning: \(reason)\n".utf8))
        generation &+= 1
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try attach(generation: generation)
        } catch {
            lastBufferAt = Date()
            FileHandle.standardError.write(Data(
                "mic restart failed: \(error) — will retry\n".utf8
            ))
        }
    }
}

/// The mic track's AAC file with a fixed mono format chosen from the first
/// route. Buffers from any later route (other rate or channel count) are
/// converted to it, and time lost between routes is filled with silence so
/// mic timestamps stay aligned with the system track. Not thread-safe.
final class MicTrackWriter {
    let format: AVAudioFormat
    private(set) var framesWritten: AVAudioFramePosition = 0
    private let file: AVAudioFile
    private var converter: AVAudioConverter?

    /// Gaps shorter than this are clock jitter, not lost audio.
    private static let gapTolerance: TimeInterval = 0.5

    init(url: URL, sampleRate: Double) throws {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Append `buffer`, which arrived `elapsed` seconds after the track's
    /// first buffer.
    func write(_ buffer: AVAudioPCMBuffer, elapsed: TimeInterval) throws {
        let expected = AVAudioFramePosition(elapsed * format.sampleRate)
        if Double(expected - framesWritten) > Self.gapTolerance * format.sampleRate {
            try writeSilence(frames: expected - framesWritten)
        }
        let mono = try convert(buffer)
        try file.write(from: mono)
        framesWritten += AVAudioFramePosition(mono.frameLength)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            guard let c = AVAudioConverter(from: buffer.format, to: format) else {
                throw MicRecorder.RecorderError.formatUnsupported(buffer.format)
            }
            converter = c
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { throw MicRecorder.RecorderError.formatUnsupported(buffer.format) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? MicRecorder.RecorderError.formatUnsupported(buffer.format) }
        return out
    }

    private func writeSilence(frames: AVAudioFramePosition) throws {
        var left = frames
        while left > 0 {
            let n = AVAudioFrameCount(min(left, 48_000))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            silence.frameLength = n
            memset(silence.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
            try file.write(from: silence)
            framesWritten += AVAudioFramePosition(n)
            left -= AVAudioFramePosition(n)
        }
    }
}
