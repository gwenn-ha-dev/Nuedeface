// Nuedeface — oreille TONALE de l'IA (et de l'UI) : spectre du mix via FFT (Accelerate/vDSP).
//
// `analyze` (LUFS/peak) = oreille de NIVEAU. Ici on ajoute une oreille de TIMBRE : à partir du mix rendu,
// une FFT fenêtrée (Hann, 50 % overlap, moyennée à la Welch) donne le spectre de puissance, réduit en
// mesures interprétables : énergie par BANDE nommée (dB), CENTROÏDE (brillance, Hz), TILT (clair/sombre, dB),
// fréquence DOMINANTE (Hz). Pas de DSP maison exotique : vDSP est natif Apple, comme le reste.

import Foundation
import Accelerate

enum Spectrum {
    struct Band { let name: String; let lo: Double; let hi: Double; let db: Double }
    struct Result { let bands: [Band]; let centroidHz: Double; let peakHz: Double; let tiltDb: Double }

    private static let bandDefs: [(String, Double, Double)] = [
        ("sub", 20, 60), ("bass", 60, 250), ("lowMid", 250, 500), ("mid", 500, 2_000),
        ("highMid", 2_000, 4_000), ("presence", 4_000, 8_000), ("air", 8_000, 20_000),
    ]

    /// Spectre de puissance moyen du mix (mono = moyenne L/R) puis réduction en bandes/centroïde/tilt.
    static func analyze(_ left: [Float], _ right: [Float], sr: Double) -> Result {
        let count = min(left.count, right.count)
        let empty = Result(bands: bandDefs.map { Band(name: $0.0, lo: $0.1, hi: $0.2, db: -120) },
                           centroidHz: 0, peakHz: 0, tiltDb: 0)
        guard count > 0 else { return empty }

        var mono = [Float](repeating: 0, count: count)
        for i in 0..<count { mono[i] = (left[i] + right[i]) * 0.5 }

        let log2n = vDSP_Length(12), n = 1 << 12, half = n / 2
        if mono.count < n { mono.append(contentsOf: [Float](repeating: 0, count: n - mono.count)) }
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return empty }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var power = [Float](repeating: 0, count: half)
        var realp = [Float](repeating: 0, count: half), imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)
        let hop = n / 2
        var start = 0, frames = 0
        while start + n <= mono.count {
            mono.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n)) }
            windowed.withUnsafeBufferPointer { wp in
                wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                    realp.withUnsafeMutableBufferPointer { rp in
                        imagp.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                            var mags = [Float](repeating: 0, count: half)
                            vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                            vDSP_vadd(power, 1, mags, 1, &power, 1, vDSP_Length(half))
                        }
                    }
                }
            }
            frames += 1; start += hop
        }
        guard frames > 0 else { return empty }
        var inv = Float(1.0 / Double(frames)); vDSP_vsmul(power, 1, &inv, &power, 1, vDSP_Length(half))
        power[0] = 0   // ignore DC (le bin 0 mêle DC et Nyquist en packing zrip ; négligeable pour le timbre)

        func freq(_ k: Int) -> Double { Double(k) * sr / Double(n) }

        var bands: [Band] = []
        for (name, lo, hi) in bandDefs {
            var sum = 0.0, cnt = 0
            for k in 1..<half { let f = freq(k); if f >= lo && f < hi { sum += Double(power[k]); cnt += 1 } }
            let mean = cnt > 0 ? sum / Double(cnt) : 0
            bands.append(Band(name: name, lo: lo, hi: hi, db: mean > 0 ? 10 * log10(mean) : -120))
        }

        var num = 0.0, den = 0.0, low = 0.0, high = 0.0, peakV = 0.0; var peakK = 1
        for k in 1..<half {
            let p = Double(power[k]), f = freq(k)
            num += f * p; den += p
            if f < 1_000 { low += p } else { high += p }
            if p > peakV { peakV = p; peakK = k }
        }
        return Result(bands: bands,
                      centroidHz: den > 0 ? num / den : 0,
                      peakHz: freq(peakK),
                      tiltDb: (low > 0 && high > 0) ? 10 * log10(high / low) : 0)
    }

    // --- spectre LIVE par trame (P1/P4) : pour dessiner le FFT qui coule derrière la courbe d'EQ. ---
    // Une seule fenêtre Hann, réduite en `bins` valeurs en dB sur l'axe LOG 20 Hz→Nyquist (mapping direct
    // sur l'axe fréquence de l'EQ). Léger : appelé au rythme télémétrie (~30 Hz), pas au taux audio.
    // INVARIANT DE QUEUE : liveSetup n'est touché que par la tick télémétrie (telemetryQ), jamais ailleurs → pas de lock.
    private static var liveSetup: (setup: FFTSetup, log2n: vDSP_Length, n: Int)?
    static func liveBins(_ samples: [Float], sr: Double, bins: Int = 96) -> [Float] {
        let n = 1024, half = n / 2, log2n = vDSP_Length(10)
        guard samples.count >= n else { return [Float](repeating: -120, count: bins) }
        if liveSetup == nil, let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) { liveSetup = (s, log2n, n) }
        guard let setup = liveSetup?.setup else { return [Float](repeating: -120, count: bins) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: n)
        // dernière fenêtre du buffer (le « maintenant »)
        let start = samples.count - n
        samples.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n)) }
        var realp = [Float](repeating: 0, count: half), imagp = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
            }
        }
        mags[0] = 0
        // réduction en bins LOG 20 Hz→Nyquist : chaque bin = max des magnitudes des fréquences couvertes.
        let fLo = 20.0, fHi = sr / 2
        func binFreq(_ b: Int) -> Double { pow(10, log10(fLo) + Double(b) / Double(bins) * (log10(fHi) - log10(fLo))) }
        var out = [Float](repeating: -120, count: bins)
        for b in 0..<bins {
            let f0 = binFreq(b), f1 = binFreq(b + 1)
            let k0 = max(1, Int(f0 * Double(n) / sr)), k1 = min(half - 1, max(k0, Int(f1 * Double(n) / sr)))
            var pk: Float = 0
            for k in k0...k1 where mags[k] > pk { pk = mags[k] }
            out[b] = pk > 0 ? Float(10 * log10(Double(pk))) : -120
        }
        return out
    }
}
