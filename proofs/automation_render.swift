// Nuedeface — proof : l'automation rend AUTRE CHOSE que le volume (pan + params d'inserts).
//   swiftc proofs/automation_render.swift -o /tmp/auto && /tmp/auto
//
// Deux mécanismes nouveaux :
//   1) PAN baké dans le buffer (loi équal-power) — pur calcul tableau, comme Engine.trackBuffer.
//      On automatise le pan de -1 → +1 et on vérifie que l'énergie passe du canal G au canal D.
//   2) PARAM D'INSERT automatisé par bloc offline — on règle le cutoff d'un AULowpass (subType "lpas")
//      AVANT chaque renderOffline (comme Engine.render), de 18 kHz → 200 Hz, et on vérifie que
//      l'énergie de sortie chute (le filtre se referme dans le temps).

import Foundation
import AVFoundation

let sr = 48_000.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
let N = Int(sr)                                  // 1 s

// lane linéaire entre deux bornes (mirroir minimal de Document.laneValue, hold aux extrémités)
func lane(_ from: Double, _ to: Double, atSample s: Int) -> Double {
    let frac = max(0, min(1, Double(s) / Double(N - 1)))
    return from + (to - from) * frac
}
func rms(_ x: [Float], _ a: Int, _ b: Int) -> Double {
    let lo = max(0, a), hi = min(x.count, b); guard hi > lo else { return 0 }
    var s = 0.0; for i in lo..<hi { s += Double(x[i]) * Double(x[i]) }; return (s / Double(hi - lo)).squareRoot()
}
let eA = Int(0.0 * sr), eB = Int(0.2 * sr)       // fenêtre « début »
let lA = Int(0.8 * sr), lB = Int(1.0 * sr)       // fenêtre « fin »

// =========================================================================================
// 1) PAN baké
// =========================================================================================
var pl = [Float](repeating: 0, count: N), pr = [Float](repeating: 0, count: N)
for i in 0..<N {
    let s = 0.5 * sinf(2 * .pi * 440 * Float(i) / Float(sr))
    pl[i] = s; pr[i] = s
    let p = lane(-1, 1, atSample: i)             // -1 (gauche) → +1 (droite)
    let theta = (p + 1.0) * Double.pi / 4.0
    pl[i] *= Float(cos(theta)); pr[i] *= Float(sin(theta))
}
let Le = rms(pl, eA, eB), Re = rms(pr, eA, eB), Ll = rms(pl, lA, lB), Rl = rms(pr, lA, lB)
print("PAN  début L/R = \(String(format: "%.3f / %.3f", Le, Re))   fin L/R = \(String(format: "%.3f / %.3f", Ll, Rl))")
let panOK = Le > Re * 1.5 && Rl > Ll * 1.5       // début à gauche, fin à droite
print("  → début à gauche & fin à droite : \(panOK ? "oui" : "NON")")

// =========================================================================================
// 2) PARAM D'INSERT automatisé par bloc (cutoff d'un lowpass)
// =========================================================================================
func fourCC(_ s: String) -> OSType { var b = Array(s.utf8.prefix(4)); while b.count < 4 { b.append(0x20) }; return b.reduce(OSType(0)) { ($0 << 8) | OSType($1) } }
func makeAU(_ sub: String) -> AVAudioUnit? {
    let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: fourCC(sub),
                                      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    return AVAudioUnitEffect(audioComponentDescription: d)
}

// bruit déterministe (LCG) → large spectre, sensible au lowpass
func noise() -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(N))!; b.frameLength = AVAudioFrameCount(N)
    var state: UInt32 = 0x12345
    for i in 0..<N {
        state = 1_664_525 &* state &+ 1_013_904_223
        let v = (Float(state >> 9) / Float(1 << 23) - 0.5) * 0.6
        b.floatChannelData![0][i] = v; b.floatChannelData![1][i] = v
    }
    return b
}

guard let lp = makeAU("lpas"), let tree = lp.auAudioUnit.parameterTree else { print("ÉCHEC : AULowpass (lpas) indisponible"); exit(1) }
guard let cutoff = tree.allParameters.first(where: { $0.displayName.localizedCaseInsensitiveContains("cutoff") || $0.displayName.localizedCaseInsensitiveContains("frequency") }) else {
    print("ÉCHEC : pas de param cutoff sur lpas"); exit(1)
}
print("\nlowpass : param automatisé = '\(cutoff.displayName)' [\(cutoff.minValue) … \(cutoff.maxValue)]")

let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
engine.attach(player); engine.attach(lp)
engine.connect(player, to: lp, format: fmt); engine.connect(lp, to: engine.mainMixerNode, format: fmt)
try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
try! engine.start()
player.scheduleBuffer(noise(), at: nil, completionHandler: nil); player.play()

let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
var left = [Float]()
let hi = Double(min(cutoff.maxValue, 18_000)), lo = 200.0
while left.count < N {
    cutoff.value = Float(lane(hi, lo, atSample: left.count))   // cutoff réglé PAR BLOC (18k → 200)
    guard (try? engine.renderOffline(512, to: out)) == .success else { break }
    let p = out.floatChannelData![0]; for i in 0..<Int(out.frameLength) { left.append(p[i]) }
}
engine.stop()

let early = rms(left, eA, eB), late = rms(left, lA, lB)
print("FILTRE  RMS début = \(String(format: "%.4f", early))   RMS fin = \(String(format: "%.4f", late))")
let filtOK = early > 0 && late < early * 0.6       // le lowpass qui se referme doit retirer de l'énergie
print("  → l'énergie chute quand le cutoff descend : \(filtOK ? "oui" : "NON")")

if panOK && filtOK {
    print("\nPASS ✓  pan baké + automation d'un param d'insert par bloc rendent bien")
} else {
    print("\nFAIL ✗  pan=\(panOK) filtre=\(filtOK)")
    exit(1)
}
