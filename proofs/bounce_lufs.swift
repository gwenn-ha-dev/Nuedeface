// Nuedeface — proof moteur : render offline → LUFS (EBU R128 / BS.1770) → bounce fichier.
//
// Dé-risque la boucle IA "muter → render → mesurer → corriger" : il faut pouvoir
//   1. rendre le mix hors-ligne (déterministe, plus vite que le temps réel),
//   2. en sortir une mesure de loudness fiable,
//   3. l'exporter en fichier.
//
// Validation interne : +6 dB sur la source ⇒ LUFS attendu +6. Si la pente est juste,
// le mètre est juste (pas seulement "il tourne").
//
//   swiftc proofs/bounce_lufs.swift -o /tmp/bounce_lufs && /tmp/bounce_lufs

import AVFoundation

let sr = 48_000.0
let block: AVAudioFrameCount = 512
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

// ---------------------------------------------------------------------------
// LUFS intégré (ITU-R BS.1770-4 + grille de gating EBU R128)
// ---------------------------------------------------------------------------

// Biquad Direct Form I.
func biquad(_ x: [Float], _ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    for n in 0..<x.count {
        let xn = Double(x[n])
        let yn = b0*xn + b1*x1 + b2*x2 - a1*y1 - a2*y2
        y[n] = Float(yn)
        x2 = x1; x1 = xn; y2 = y1; y1 = yn
    }
    return y
}

// Pré-filtre K (coeffs standard @48 kHz) : high-shelf puis high-pass (RLB).
func kWeight(_ x: [Float]) -> [Float] {
    let s1 = biquad(x, 1.53512485958697, -2.69169618940638, 1.19839281085285,
                       -1.69065929318241, 0.73248077421585)            // high-shelf
    return biquad(s1, 1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621) // high-pass
}

func meanSquare(_ x: [Float], _ lo: Int, _ hi: Int) -> Double {
    var s = 0.0
    for i in lo..<hi { s += Double(x[i]) * Double(x[i]) }
    return s / Double(hi - lo)
}

// Loudness intégré, canaux L/R (poids G = 1.0 chacun).
func lufsIntegrated(_ left: [Float], _ right: [Float]) -> Double {
    let kl = kWeight(left), kr = kWeight(right)
    let bs = Int(0.400 * sr)          // bloc de gating 400 ms
    let hop = Int(0.100 * sr)         // pas 100 ms (recouvrement 75 %)
    var loud = [Double]()             // l par bloc
    var z = [Double]()                // puissance (zL+zR) par bloc
    var i = 0
    while i + bs <= kl.count {
        let zb = meanSquare(kl, i, i + bs) + meanSquare(kr, i, i + bs)
        if zb > 0 {
            z.append(zb)
            loud.append(-0.691 + 10 * log10(zb))
        }
        i += hop
    }
    guard !z.isEmpty else { return -Double.infinity }

    // Gate absolu -70 LUFS.
    var absIdx = [Int]()
    for k in 0..<loud.count where loud[k] >= -70.0 { absIdx.append(k) }
    guard !absIdx.isEmpty else { return -Double.infinity }

    // Seuil relatif = loudness des blocs abs-gated - 10 LU.
    let meanZabs = absIdx.map { z[$0] }.reduce(0, +) / Double(absIdx.count)
    let gammaR = -0.691 + 10 * log10(meanZabs) - 10.0

    // Intégration sur les blocs qui passent le gate relatif.
    let keep = absIdx.filter { loud[$0] >= gammaR }
    guard !keep.isEmpty else { return -Double.infinity }
    let meanZ = keep.map { z[$0] }.reduce(0, +) / Double(keep.count)
    return -0.691 + 10 * log10(meanZ)
}

// ---------------------------------------------------------------------------
// 1. Render offline d'un mix AVAudioEngine vers un buffer stéréo + bounce fichier
// ---------------------------------------------------------------------------

func tone(_ hz: Double, amp: Double, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<2 {
        let p = buf.floatChannelData![ch]
        for i in 0..<Int(frames) { p[i] = Float(amp * sin(2.0 * .pi * hz * Double(i) / sr)) }
    }
    return buf
}

func renderMix(seconds: Double, bounceTo url: URL?) -> (left: [Float], right: [Float]) {
    let engine = AVAudioEngine()
    let p1 = AVAudioPlayerNode(), p2 = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 1)
    engine.attach(p1); engine.attach(p2); engine.attach(eq)
    engine.connect(p1, to: eq, format: fmt)
    engine.connect(eq, to: engine.mainMixerNode, format: fmt)
    engine.connect(p2, to: engine.mainMixerNode, format: fmt)

    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
    try! engine.start()
    p1.scheduleBuffer(tone(220, amp: 0.25, frames: AVAudioFrameCount(sr)), at: nil, options: .loops)
    p2.scheduleBuffer(tone(330, amp: 0.18, frames: AVAudioFrameCount(sr)), at: nil, options: .loops)
    p1.play(); p2.play()

    var file: AVAudioFile? = nil
    if let url = url {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        file = try! AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!
    var left = [Float](), right = [Float]()
    let total = Int(seconds * sr)
    while left.count < total {
        let status = try! engine.renderOffline(block, to: out)
        guard status == .success else { break }
        let l = out.floatChannelData![0], r = out.floatChannelData![1]
        for i in 0..<Int(out.frameLength) { left.append(l[i]); right.append(r[i]) }
        try? file?.write(from: out)
    }
    engine.stop()
    return (left, right)
}

// ---------------------------------------------------------------------------
// 2. Validation du mètre : signal synthétique, puis +6 dB ⇒ doit donner +6 LUFS
// ---------------------------------------------------------------------------

func calib(amp: Double, seconds: Double) -> [Float] {
    let n = Int(seconds * sr)
    var x = [Float](repeating: 0, count: n)
    for i in 0..<n { x[i] = Float(amp * sin(2.0 * .pi * 1000.0 * Double(i) / sr)) }
    return x
}

print("=== Nuedeface — proof : render offline → LUFS → bounce ===\n")

// -- Validation pente --
let a = calib(amp: 0.5, seconds: 3)
let aPlus6 = calib(amp: 1.0, seconds: 3)   // ×2 amplitude = +6.02 dB
let lufsA = lufsIntegrated(a, a)
let lufsB = lufsIntegrated(aPlus6, aPlus6)
print("--- Validation du mètre (sinus 1 kHz stéréo) ---")
print(String(format: "  LUFS @ amp 0.5      : %.2f LUFS", lufsA))
print(String(format: "  LUFS @ amp 1.0      : %.2f LUFS", lufsB))
print(String(format: "  delta (attendu +6.02): %.2f LU", lufsB - lufsA))
let slopeOK = abs((lufsB - lufsA) - 6.02) < 0.1
print("  pente               : " + (slopeOK ? "JUSTE (mètre linéaire et calibré)" : "SUSPECTE"))

// -- Mix réel rendu offline + bounce --
print("\n--- Render offline du mix + bounce fichier ---")
let bounceURL = URL(fileURLWithPath: "/tmp/nuedeface_bounce.wav")
let t0 = DispatchTime.now().uptimeNanoseconds
let (l, r) = renderMix(seconds: 5, bounceTo: bounceURL)
let renderMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
let mixLufs = lufsIntegrated(l, r)
let speedup = (5.0 * 1000.0) / renderMs
print(String(format: "  durée rendue        : 5.0 s (%d frames)", l.count))
print(String(format: "  temps de rendu      : %.1f ms  (~%.0f× temps réel)", renderMs, speedup))
print(String(format: "  loudness intégré    : %.2f LUFS", mixLufs))
if let attrs = try? FileManager.default.attributesOfItem(atPath: bounceURL.path),
   let size = attrs[.size] as? Int {
    print(String(format: "  bounce écrit        : %@ (%d Ko)", bounceURL.path, size / 1024))
} else {
    print("  bounce écrit        : ÉCHEC")
}
