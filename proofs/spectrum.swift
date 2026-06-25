// Nuedeface — proof : l'oreille TONALE (FFT) lit bien le spectre.
//   swiftc proofs/spectrum.swift -o /tmp/spec && /tmp/spec
//
// Sur des signaux CONNUS : un sinus pur à f doit donner peak ≈ f et centroïde ≈ f ; un signal aigu doit avoir
// une centroïde et un tilt plus élevés qu'un signal grave. (Même algo que src/Spectrum.swift.)

import Foundation
import Accelerate

let sr = 48_000.0

func centroidPeakTilt(_ mono0: [Float]) -> (centroid: Double, peak: Double, tilt: Double) {
    var mono = mono0
    let log2n = vDSP_Length(12), n = 1 << 12, half = n / 2
    if mono.count < n { mono.append(contentsOf: [Float](repeating: 0, count: n - mono.count)) }
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: n); vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var power = [Float](repeating: 0, count: half), realp = [Float](repeating: 0, count: half), imagp = [Float](repeating: 0, count: half)
    var windowed = [Float](repeating: 0, count: n)
    var start = 0, frames = 0; let hop = n / 2
    while start + n <= mono.count {
        mono.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n)) }
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                realp.withUnsafeMutableBufferPointer { rp in imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    var mags = [Float](repeating: 0, count: half); vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    vDSP_vadd(power, 1, mags, 1, &power, 1, vDSP_Length(half))
                }}
            }
        }
        frames += 1; start += hop
    }
    power[0] = 0
    func f(_ k: Int) -> Double { Double(k) * sr / Double(n) }
    var num = 0.0, den = 0.0, low = 0.0, high = 0.0, peakV = 0.0; var peakK = 1
    for k in 1..<half { let p = Double(power[k]), fk = f(k); num += fk*p; den += p; if fk < 1000 { low += p } else { high += p }; if p > peakV { peakV = p; peakK = k } }
    return (den > 0 ? num/den : 0, f(peakK), (low > 0 && high > 0) ? 10*log10(high/low) : 0)
}

func sine(_ hz: Double, _ secs: Double = 0.3, amp: Float = 0.5) -> [Float] {
    let N = Int(secs * sr); return (0..<N).map { amp * sinf(2 * .pi * Float(hz) * Float($0) / Float(sr)) }
}

// 1) sinus pur à 1 kHz → peak et centroïde ≈ 1 kHz
let s1k = centroidPeakTilt(sine(1000))
print(String(format: "sinus 1 kHz   → peak %.0f Hz, centroïde %.0f Hz", s1k.peak, s1k.centroid))
let pure = abs(s1k.peak - 1000) < 20 && abs(s1k.centroid - 1000) < 60

// 2) aigu (6 kHz) vs grave (200 Hz) → centroïde et tilt ordonnés
let bright = centroidPeakTilt(sine(6000)), dark = centroidPeakTilt(sine(200))
print(String(format: "sinus 6 kHz   → centroïde %.0f Hz, tilt %+.1f dB (clair)", bright.centroid, bright.tilt))
print(String(format: "sinus 200 Hz  → centroïde %.0f Hz, tilt %+.1f dB (sombre)", dark.centroid, dark.tilt))
let ordered = bright.centroid > dark.centroid && bright.tilt > 0 && dark.tilt < 0

if pure && ordered { print("\nPASS ✓  l'oreille tonale lit peak/centroïde/tilt correctement") }
else { print("\nFAIL ✗  pure=\(pure) ordered=\(ordered)"); exit(1) }
