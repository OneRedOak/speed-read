import Accelerate
import AVFoundation

/// WSOLA time-stretch for speech (Waveform Similarity Overlap-Add).
///
/// AVAudioUnitTimePitch is a phase vocoder: it stretches in the frequency
/// domain, which smears transients across analysis windows — audible on
/// speech as a reverberant, "bright room" quality at higher rates. WSOLA
/// works in the time domain: it splices ~23 ms waveform chunks at their
/// point of maximum normalized cross-correlation, so each output sample is
/// a locally raised-cosine cross-faded copy of real input — no spectral
/// smearing and no amplitude-bias clicks on plosives.
///
/// Mono float PCM in, mono float PCM out; output duration ≈ input / rate.
/// Rate 1.0 (±0.001) returns the input untouched.
public enum TimeStretch {
    /// Analysis/synthesis window (~23 ms @ 44.1 kHz).
    static let windowLength = 1024
    /// Cross-fade region between spliced chunks (~11.6 ms @ 44.1 kHz).
    static let overlap = 512
    /// Search radius for the best splice point (~10 ms @ 44.1 kHz).
    static let searchRadius = 441

    /// Precomputed raised-cosine (Hann) cross-fade ramps (`fadeIn[i] + fadeOut[i] == 1`).
    /// C¹-continuous at both endpoints, preventing slope discontinuities at splices.
    private static let fadeIn: [Float] = {
        (0..<overlap).map { i in
            let phase = Double.pi * (Double(i) + 0.5) / Double(overlap)
            return Float(0.5 * (1.0 - cos(phase)))
        }
    }()

    private static let fadeOut: [Float] = {
        fadeIn.map { 1.0 - $0 }
    }()

    public static func stretch(_ input: AVAudioPCMBuffer, rate: Double) -> AVAudioPCMBuffer {
        let n = Int(input.frameLength)
        guard abs(rate - 1.0) > 0.001,
              rate > 0,
              n > windowLength + searchRadius + 1,
              input.format.channelCount == 1,
              let inPtr = input.floatChannelData?[0] else {
            return input
        }

        let synthesisHop = windowLength - overlap                 // output stride (512)
        let analysisHop = Double(synthesisHop) * rate             // input stride

        let capacity = Int(Double(n) / rate) + 2 * windowLength
        guard let output = AVAudioPCMBuffer(
            pcmFormat: input.format,
            frameCapacity: AVAudioFrameCount(capacity)),
            let outPtr = output.floatChannelData?[0] else {
            return input
        }

        // Precompute cumulative sample energy in O(n) using SIMD square so
        // every candidate window's L2 energy is an O(1) subtraction.
        var squared = [Float](repeating: 0, count: n)
        vDSP_vsq(inPtr, 1, &squared, 1, vDSP_Length(n))
        var prefixEnergy = [Double](repeating: 0, count: n + 1)
        var running = 0.0
        for i in 0..<n {
            running += Double(squared[i])
            prefixEnergy[i + 1] = running
        }

        // Scratch buffer for vectorized cross-correlation across all candidate lags.
        let maxSearchCount = 2 * searchRadius + 1
        var corr = [Float](repeating: 0, count: maxSearchCount)

        // Seed: first window verbatim.
        outPtr.update(from: inPtr, count: windowLength)
        var outLength = windowLength
        var previousChosen = 0
        var inputPosition = 0.0

        while true {
            inputPosition += analysisHop
            let nominal = Int(inputPosition.rounded())
            let maxStart = n - windowLength
            guard nominal <= maxStart, outLength + synthesisHop <= capacity else { break }

            let low = max(0, nominal - searchRadius)
            let high = min(maxStart, nominal + searchRadius)
            let templateStart = previousChosen + synthesisHop
            guard low <= high, templateStart + overlap <= n else { break }

            let templateEnergy = prefixEnergy[templateStart + overlap] - prefixEnergy[templateStart]
            let bestOffset: Int
            if templateEnergy < 1e-7 {
                // Silent region: skip correlation and hold nominal cadence so
                // inter-sentence pauses don't drift backward into sentence onsets.
                bestOffset = nominal
            } else {
                let count = high - low + 1
                let template = inPtr + templateStart
                // Single SIMD correlation pass computes all `count` dot products at once.
                // With positive filter stride (+1), vDSP_conv computes cross-correlation:
                // corr[k] = sum_{p=0..<overlap} input[low + k + p] * template[p].
                vDSP_conv(
                    inPtr + low, 1,
                    template, 1,
                    &corr, 1,
                    vDSP_Length(count),
                    vDSP_Length(overlap)
                )

                var bestIndex = nominal - low
                var bestScore = -Float.greatestFiniteMagnitude
                for k in 0..<count {
                    let candStart = low + k
                    let candEnergy = prefixEnergy[candStart + overlap] - prefixEnergy[candStart]
                    // Normalize by candidate RMS energy (template energy is constant
                    // across k) so plosive onsets don't hijack phase alignment.
                    let denom = Float(sqrt(max(candEnergy, 0.0) + 1e-9))
                    let score = corr[k] / denom
                    if score > bestScore {
                        bestScore = score
                        bestIndex = k
                    }
                }
                bestOffset = low + bestIndex
            }

            // Vectorized raised-cosine cross-fade of output tail into chosen chunk.
            let tail = outPtr + (outLength - overlap)
            let chosen = inPtr + bestOffset
            vDSP_vmul(tail, 1, fadeOut, 1, tail, 1, vDSP_Length(overlap))
            vDSP_vma(chosen, 1, fadeIn, 1, tail, 1, tail, 1, vDSP_Length(overlap))

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
