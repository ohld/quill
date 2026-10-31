import AVFoundation
import XCTest
@testable import quill

final class MicTrackWriterTests: XCTestCase {
    /// Regression for the 2026-10-31 empty mic track: capture restarts on a
    /// new route (different rate and channel count) must keep writing to the
    /// same file, with the dead interval padded so the track stays aligned.
    func testRouteChangeResamplesAndPadsGap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = 48_000.0 * 4
        do {
            let writer = try MicTrackWriter(url: url, sampleRate: 48_000)
            // 1 s from a 3-channel 48 kHz route.
            try writer.write(tone(sampleRate: 48_000, channels: 3, seconds: 1), elapsed: 0)
            // Route dies, capture resumes 3 s later on a 1-channel 24 kHz route.
            try writer.write(tone(sampleRate: 24_000, channels: 1, seconds: 1), elapsed: 3)
            XCTAssertEqual(Double(writer.framesWritten), expected, accuracy: 48_000 * 0.05)
        }  // releasing the writer finalizes the AAC file

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length), expected, accuracy: 48_000 * 0.1)
    }

    private func tone(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) -> AVAudioPCMBuffer {
        // >2 channels need a layout; a discrete layout matches what the
        // MacBook mic array reports.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![ch][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / Float(sampleRate))
            }
        }
        return buffer
    }
}
