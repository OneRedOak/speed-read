import AVFoundation
import Foundation
import Testing
@testable import SRCore

@Suite struct TimeStretchTests {
    private func sineBuffer(seconds: Double, frequency: Double = 220,
                            sampleRate: Double = 44_100) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            data[i] = sinf(Float(2.0 * .pi * frequency * Double(i) / sampleRate)) * 0.5
        }
        return buffer
    }

    @Test(arguments: [0.5, 0.75, 1.25, 1.5, 2.0, 2.5, 3.0])
    func stretchedLengthMatchesRate(rate: Double) {
        let input = sineBuffer(seconds: 2.0)
        let output = TimeStretch.stretch(input, rate: rate)
        let expected = Double(input.frameLength) / rate
        let actual = Double(output.frameLength)
        // WSOLA quantizes to hop boundaries; ±1 window + tail of tolerance.
        let tolerance = expected * 0.06 + 4096
        #expect(abs(actual - expected) < tolerance,
                "rate \(rate): expected ≈\(Int(expected)) frames, got \(Int(actual))")
    }

    @Test func unityRateIsPassthrough() {
        let input = sineBuffer(seconds: 0.5)
        let output = TimeStretch.stretch(input, rate: 1.0)
        #expect(output === input)
    }

    @Test func shortInputPassesThrough() {
        let input = sineBuffer(seconds: 0.01)  // shorter than one window
        let output = TimeStretch.stretch(input, rate: 2.0)
        #expect(output === input)
    }

    @Test func outputIsFiniteAndNonSilent() {
        let input = sineBuffer(seconds: 1.0)
        let output = TimeStretch.stretch(input, rate: 2.0)
        let data = output.floatChannelData![0]
        var peak: Float = 0
        for i in 0..<Int(output.frameLength) {
            #expect(data[i].isFinite)
            peak = max(peak, abs(data[i]))
        }
        // A stretched 0.5-amplitude sine keeps roughly its amplitude.
        #expect(peak > 0.3 && peak < 1.0)
    }

    @Test func silenceStaysSilent() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        let output = TimeStretch.stretch(buffer, rate: 2.0)
        let data = output.floatChannelData![0]
        var peak: Float = 0
        for i in 0..<Int(output.frameLength) {
            peak = max(peak, abs(data[i]))
        }
        #expect(peak == 0)
    }

    @Test func leadingSilencePreservesCadenceAndSpeechOnset() {
        // 0.4 s silence + 1.0 s 220 Hz tone stretched at 2.0× should start
        // speech near 0.2 s (~8,820 frames), not drifted early/late.
        let sr = 44_100.0
        let silenceFrames = Int(0.4 * sr)
        let toneFrames = Int(1.0 * sr)
        let total = silenceFrames + toneFrames
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let ptr = buffer.floatChannelData![0]
        for i in 0..<silenceFrames { ptr[i] = 0 }
        for i in 0..<toneFrames {
            ptr[silenceFrames + i] = sinf(Float(2.0 * .pi * 220.0 * Double(i) / sr)) * 0.5
        }

        let output = TimeStretch.stretch(buffer, rate: 2.0)
        let outPtr = output.floatChannelData![0]
        var firstNonZero = Int(output.frameLength)
        for i in 0..<Int(output.frameLength) {
            if abs(outPtr[i]) > 0.05 {
                firstNonZero = i
                break
            }
        }
        let expectedOnset = Double(silenceFrames) / 2.0
        #expect(abs(Double(firstNonZero) - expectedOnset) < 2048,
                "expected onset near \(Int(expectedOnset)), got \(firstNonZero)")
    }
}
