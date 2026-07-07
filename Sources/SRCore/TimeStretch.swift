import Accelerate
import AVFoundation

/// WSOLA time-stretch for speech (Waveform Similarity Overlap-Add).
///
/// AVAudioUnitTimePitch is a phase vocoder: it stretches in the frequency
/// domain, which smears transients across analysis windows — audible on
/// speech as a reverberant, "bright room" quality at higher rates. WSOLA
/// works in the time domain: it splices ~23 ms waveform chunks at their
/// point of maximum cross-correlation, so each output sample is a (locally
/// cross-faded) copy of real input — no spectral smearing. This is the
/// approach speech/podcast players use.
///
/// Mono float PCM in, mono float PCM out; output duration ≈ input / rate.
/// Rate 1.0 (±0.001) returns the input untouched.
public enum TimeStretch {
    /// Analysis/synthesis window (~23 ms @ 44.1 kHz).
    static let windowLength = 1024
    /// Cross-fade region between spliced chunks.
    static let overlap = 512
    /// Search radius for the best splice point (~10 ms @ 44.1 kHz).
    static let searchRadius = 441

    public static func stretch(_ input: AVAudioPCMBuffer, rate: Double) -> AVAudioPCMBuffer {
        let n = Int(input.frameLength)
        guard abs(rate - 1.0) > 0.001,
              rate > 0,
              n > windowLength + searchRadius + 1,
              input.format.channelCount == 1,
              let inPtr = input.floatChannelData?[0] else {
            return input
        }

        let synthesisHop = windowLength - overlap                 // output stride
        let analysisHop = Double(synthesisHop) * rate             // input stride

        let capacity = Int(Double(n) / rate) + 2 * windowLength
        guard let output = AVAudioPCMBuffer(
            pcmFormat: input.format,
            frameCapacity: AVAudioFrameCount(capacity)),
            let outPtr = output.floatChannelData?[0] else {
            return input
        }

        // Seed: first window verbatim.
        outPtr.update(from: inPtr, count: windowLength)
        var outLength = windowLength
        var previousChosen = 0
        var inputPosition = 0.0

        while true {
            inputPosition += analysisHop
            let nominal = Int(inputPosition.rounded())
            let low = max(0, nominal - searchRadius)
            let high = nominal + searchRadius
            guard high + windowLength <= n, outLength + synthesisHop <= capacity else { break }

            // The seamless continuation of the previous chunk is
            // input[previousChosen + synthesisHop ...]; find the candidate
            // near `nominal` that best matches it (max cross-correlation).
            let template = inPtr + previousChosen + synthesisHop
            var bestOffset = low
            var bestScore = -Float.greatestFiniteMagnitude
            var candidate = low
            while candidate <= high {
                var score: Float = 0
                vDSP_dotpr(template, 1, inPtr + candidate, 1, &score, vDSP_Length(overlap))
                if score > bestScore {
                    bestScore = score
                    bestOffset = candidate
                }
                candidate += 1
            }

            // Cross-fade the output tail into the chosen chunk.
            let tail = outPtr + (outLength - overlap)
            let chosen = inPtr + bestOffset
            for i in 0..<overlap {
                let t = Float(i) / Float(overlap)
                tail[i] = tail[i] * (1 - t) + chosen[i] * t
            }
            // Append the non-overlapping remainder of the chunk.
            (outPtr + outLength).update(from: chosen + overlap, count: synthesisHop)
            outLength += synthesisHop
            previousChosen = bestOffset
        }

        // Tail: whatever follows the last chosen window, verbatim.
        let tailStart = previousChosen + windowLength
        if tailStart < n {
            let remaining = min(n - tailStart, capacity - outLength)
            if remaining > 0 {
                (outPtr + outLength).update(from: inPtr + tailStart, count: remaining)
                outLength += remaining
            }
        }

        output.frameLength = AVAudioFrameCount(outLength)
        return output
    }
}
