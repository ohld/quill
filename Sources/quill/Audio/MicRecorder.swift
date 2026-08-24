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
    private var file: AVAudioFile?
    private var url: URL?
    private var recording = false
    private var generation: UInt64 = 0
    private var capturedFirstBufferAt: Date?

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
        self.url = url
        do {
            try attach(voiceProcessing: voiceProcessing, generation: generation)
            recording = true
        } catch {
            file = nil
            self.url = nil
            throw error
        }
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard recording else { return }

        recording = false
        generation &+= 1
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // No tap can be writing here: an existing writer had to release the
        // same lock before stop acquired it, and new callbacks use try().
        file = nil
        url = nil
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, and start capture. Called
    /// once at start, and a second time (voiceProcessing: false) if the
    /// liveness check trips.
    /// `stateLock` must be held by the caller.
    private func attach(voiceProcessing: Bool, generation: UInt64) throws {
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

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url!,
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat, generation: generation)
        } else {
            try installRawTap(
                on: input,
                inputFormat: inputFormat,
                monoFormat: monoFormat,
                generation: generation
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.engineStartFailed(error)
        }

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        generation: UInt64
    ) {
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, self.stateLock.try() else { return }
            defer { self.stateLock.unlock() }
            guard self.recording,
                  self.generation == generation,
                  let file = self.file else { return }
            self.markFirstBufferLocked()

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { [weak self] in
                            self?.fallBackToRaw(expectedGeneration: generation)
                        }
                        return
                    }
                }
            }

            do {
                try file.write(from: buffer)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat,
        generation: UInt64
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.stateLock.try() else { return }
            defer { self.stateLock.unlock() }
            guard self.recording,
                  self.generation == generation,
                  let file = self.file else { return }
            self.markFirstBufferLocked()
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: buffer.frameCapacity
            ) else { return }
            do {
                try converter.convert(to: mono, from: buffer)
                try file.write(from: mono)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw(expectedGeneration: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard recording, generation == expectedGeneration else { return }

        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        generation &+= 1
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        capturedFirstBufferAt = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try attach(voiceProcessing: false, generation: generation)
        } catch {
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            file = nil
        }
    }

    /// `stateLock` must be held by the caller.
    private func markFirstBufferLocked() {
        if capturedFirstBufferAt == nil { capturedFirstBufferAt = Date() }
    }
}
