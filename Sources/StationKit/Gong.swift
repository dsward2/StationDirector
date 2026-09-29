import Foundation

/// A big struck gong (a tam-tam, the Gong Show kind), synthesized rather than
/// sampled so there's no audio file to ship: a noisy strike and low thump, a
/// cloud of inharmonic partials in slightly detuned pairs (the shimmer), mid
/// and high partials that swell in after the hit (a tam-tam's bloom), and a
/// low hum that sags a little in pitch as it rings. Deterministic, so every
/// skip sounds the same. 48 kHz / 2 ch S16LE, like every announcer clip.
enum Gong {
    static let duration = 8.0

    static func render() -> Data {
        let rate = Double(AudioGraph.sampleRate)
        let frames = Int(duration * rate)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var rng = SplitMix(seed: 0x6F6E67)      // "ong"

        // Partials: log-spaced 70 Hz – 5.5 kHz with jitter so nothing lines
        // up harmonically. Low ones ring for seconds, high ones die fast;
        // the mid/high ones bloom in over the first half second.
        let count = 44
        for i in 0..<count {
            let position = Double(i) / Double(count - 1)
            let base = 70 * pow(5500 / 70, position) * (1 + rng.uniform(-0.06, 0.06))
            let amplitude = 0.9 * pow(70 / base, 0.35) * rng.uniform(0.5, 1.0)
            let decay = 9 * pow(70 / base, 0.3) + 1.2             // seconds to ~-60 dB
            let bloom = position > 0.25 ? rng.uniform(0.3, 1.2) * position : 0.0
            for (channel, detune) in [(0, rng.uniform(-0.9, 0.9)), (1, rng.uniform(-0.9, 0.9))] {
                let phase1 = rng.uniform(0, 2 * .pi), phase2 = rng.uniform(0, 2 * .pi)
                let beat = 1 + rng.uniform(0.0015, 0.006)         // the detuned twin
                if channel == 0 {
                    addPartial(to: &left, rate: rate, frequency: base + detune, twin: beat, amplitude: amplitude,
                               decay: decay, bloom: bloom, phases: (phase1, phase2))
                } else {
                    addPartial(to: &right, rate: rate, frequency: base + detune, twin: beat, amplitude: amplitude,
                               decay: decay, bloom: bloom, phases: (phase1, phase2))
                }
            }
        }

        // The hum: ~62 Hz, starts a few percent sharp and settles.
        for n in 0..<frames {
            let t = Double(n) / rate
            // Phase of 62·(1 + 0.035·e^(-t/0.8)) Hz, integrated.
            let phase = 2 * Double.pi * 62 * (t + 0.035 * 0.8 * (1 - exp(-t / 0.8)))
            let s = Float(0.3 * exp(-t * 6.9 / 9) * sin(phase))
            left[n] += s
            right[n] += s
        }

        // The strike: a short bright noise burst plus a thump.
        var lowL: Float = 0, lowR: Float = 0
        for n in 0..<Int(0.25 * rate) {
            let t = Double(n) / rate
            let env = Float(exp(-t / 0.045))
            let noiseL = Float(rng.uniform(-1, 1)), noiseR = Float(rng.uniform(-1, 1))
            lowL += 0.35 * (noiseL - lowL)                        // soften the hiss a little
            lowR += 0.35 * (noiseR - lowR)
            let thump = Float(0.45 * exp(-t / 0.09) * sin(2 * Double.pi * 48 * t))
            left[n] += 0.9 * env * lowL + thump
            right[n] += 0.9 * env * lowR + thump
        }

        // Normalize, fade the last half second, write S16LE interleaved.
        let peak = max(left.map(abs).max() ?? 1, right.map(abs).max() ?? 1)
        let gain = 0.85 / max(peak, 0.0001)
        let fadeFrames = Int(0.5 * rate)
        var pcm = Data(capacity: frames * 4)
        for n in 0..<frames {
            let fade = n >= frames - fadeFrames ? Float(frames - n) / Float(fadeFrames) : 1
            for sample in [left[n], right[n]] {
                let value = Int16(max(-1, min(1, sample * gain * fade)) * 32767)
                withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        return pcm
    }

    private static func addPartial(to buffer: inout [Float], rate: Double, frequency: Double, twin: Double,
                                   amplitude: Double, decay: Double, bloom: Double, phases: (Double, Double)) {
        let k = 6.9 / decay                                       // e^-6.9 ≈ -60 dB
        let w1 = 2 * Double.pi * frequency / rate
        let w2 = w1 * twin
        let stop = min(buffer.count, Int((decay * 1.1) * rate))
        for n in 0..<stop {
            let t = Double(n) / rate
            let rise = bloom > 0 ? 1 - exp(-t / bloom) : 1
            let env = amplitude * exp(-k * t) * rise
            buffer[n] += Float(env * 0.5 * (sin(w1 * Double(n) + phases.0) + sin(w2 * Double(n) + phases.1)))
        }
    }
}

/// Small seeded generator so the gong is identical every time.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(next() >> 11) / Double(1 << 53)
    }
}
