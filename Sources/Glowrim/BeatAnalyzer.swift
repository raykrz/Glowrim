import Foundation
import CoreAudio

/// Turns raw system-audio buffers into a smooth 0...1 "light level".
/// Runs on the audio thread; `level` is read from the main thread.
final class BeatAnalyzer: @unchecked Sendable {
    private let lock = NSLock()

    private var coeff: Float = 0          // one-pole low-pass coefficient (~160 Hz)
    private var lp1: Float = 0, lp2: Float = 0
    private var avg: Float = 0            // short-term average energy
    private var peak: Float = 0.0001      // slowly decaying peak (auto-gain)
    private var env: Float = 0            // smoothed loudness
    private var pulse: Float = 0          // decaying beat flash
    private var lastBeat: TimeInterval = 0
    private var _level: Float = 0
    private var _sensitivity: Float = 0.5
    private var mono = [Float](repeating: 0, count: 8192)

    init() { setSampleRate(48_000) }

    func setSampleRate(_ sr: Double) {
        lock.lock(); defer { lock.unlock() }
        coeff = 1 - expf(Float(-2 * Double.pi * 160 / max(sr, 8_000)))
    }

    var sensitivity: Float {
        get { lock.lock(); defer { lock.unlock() }; return _sensitivity }
        set { lock.lock(); _sensitivity = max(0, min(1, newValue)); lock.unlock() }
    }

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        lp1 = 0; lp2 = 0; avg = 0; peak = 0.0001; env = 0; pulse = 0; _level = 0
    }

    func process(_ abl: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard list.count > 0 else { return }
        let ch0 = max(1, Int(list[0].mNumberChannels))
        let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size / ch0
        guard frames > 0 else { return }

        lock.lock(); defer { lock.unlock() }

        // Mix every channel of every buffer down to mono (handles interleaved and planar),
        // one buffer at a time into a reused scratch array.
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
        var channels = 0
        mono.withUnsafeMutableBufferPointer { out in
            for i in 0..<frames { out[i] = 0 }
            for b in list {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = max(1, Int(b.mNumberChannels))
                let n = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.size / ch)
                channels += ch
                if ch == 1 {
                    for i in 0..<n { out[i] += p[i] }
                } else {
                    for i in 0..<n {
                        var sum: Float = 0
                        for k in 0..<ch { sum += p[i * ch + k] }
                        out[i] += sum
                    }
                }
            }
        }
        let inv: Float = 1 / Float(max(1, channels))

        var a1 = lp1, a2 = lp2
        let c = coeff
        var bassSum: Float = 0, fullSum: Float = 0

        for i in 0..<frames {
            let x = mono[i] * inv
            a1 += c * (x - a1)
            a2 += c * (a1 - a2)          // 2-pole low-pass → kick drum / bass
            bassSum += a2 * a2
            fullSum += x * x
        }
        lp1 = a1; lp2 = a2

        let bass = sqrtf(bassSum / Float(frames))
        let full = sqrtf(fullSum / Float(frames))
        let e = bass * 0.75 + full * 0.25

        avg = avg * 0.96 + e * 0.04
        peak = max(e, peak * 0.9993)

        let silent = peak < 0.003
        let norm: Float = silent ? 0 : min(1, e / peak)

        let now = ProcessInfo.processInfo.systemUptime
        let threshold: Float = 1.15 + (1 - _sensitivity) * 0.6
        pulse *= 0.9
        if !silent, e > avg * threshold, e > peak * 0.25, now - lastBeat > 0.16 {
            pulse = 1
            lastBeat = now
        }

        // Fast attack, slow release.
        env += (norm - env) * (norm > env ? 0.5 : 0.07)
        _level = min(1, env * 0.6 + pulse * 0.55)
    }
}
