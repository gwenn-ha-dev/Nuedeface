// Nuedeface — proof : l'insert GÉNÉRIQUE « au » atteint vraiment le DSP.
//   swiftc proofs/au_generic.swift -o /tmp/au && /tmp/au
//
// Tranche le point dur de la palette d'effets : prouver qu'on peut instancier N'IMPORTE QUELLE
// Audio Unit effet Apple par le MÊME chemin que nos wrappers typés (AVAudioUnitEffect + AUParameterTree),
// régler ses params par leur identifier, et que ça change le son. Cobaye : AUDynamicsProcessor ("dcmp",
// le compresseur). Mesure : un compresseur RÉDUIT l'écart loud/quiet (la dynamique). On vérifie que
// l'écart en sortie est nettement plus petit qu'à l'entrée → le param threshold a bien touché le DSP.

import Foundation
import AVFoundation

let sr = 48_000.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

// --- signal de test : 0.5 s fort (-6 dBFS) puis 0.5 s faible (-34 dBFS), sinus 1 kHz ---
let total = Int(sr)                       // 1 s
let half = total / 2
let loudAmp: Float = 0.5                   // ≈ -6 dBFS
let quietAmp: Float = 0.02                 // ≈ -34 dBFS
func makeSource() -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total))!
    buf.frameLength = AVAudioFrameCount(total)
    for i in 0..<total {
        let amp = i < half ? loudAmp : quietAmp
        let s = amp * sinf(2 * .pi * 1_000 * Float(i) / Float(sr))
        buf.floatChannelData![0][i] = s; buf.floatChannelData![1][i] = s
    }
    return buf
}

// --- RMS (dB) d'une fenêtre [a,b) du canal gauche ---
func rmsDB(_ x: [Float], _ a: Int, _ b: Int) -> Double {
    let lo = max(0, a), hi = min(x.count, b)
    guard hi > lo else { return -120 }
    var s = 0.0; for i in lo..<hi { s += Double(x[i]) * Double(x[i]) }
    return 10 * log10(max(1e-12, s / Double(hi - lo)))
}

// --- LE chemin générique : exactement ce que fait Engine.AU.make(_:) ---
func makeAU(_ subType: String) -> AVAudioUnit? {
    func fourCC(_ s: String) -> OSType {
        var b = Array(s.utf8.prefix(4)); while b.count < 4 { b.append(0x20) }
        return b.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }
    let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                         componentSubType: fourCC(subType),
                                         componentManufacturer: kAudioUnitManufacturer_Apple,
                                         componentFlags: 0, componentFlagsMask: 0)
    return AVAudioUnitEffect(audioComponentDescription: desc)
}

// --- render offline d'une source à travers l'AU (nil = à sec) ---
func render(through au: AVAudioUnit?) -> [Float] {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    var upstream: AVAudioNode = player
    if let au = au { engine.attach(au); engine.connect(player, to: au, format: fmt); upstream = au }
    engine.connect(upstream, to: engine.mainMixerNode, format: fmt)

    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
    try! engine.start()
    player.scheduleBuffer(makeSource(), at: nil, completionHandler: nil); player.play()

    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    var left = [Float]()
    while left.count < total {
        guard (try? engine.renderOffline(512, to: out)) == .success else { break }
        let p = out.floatChannelData![0]
        for i in 0..<Int(out.frameLength) { left.append(p[i]) }
    }
    engine.stop()
    return left
}

// --- 1) instancier le compresseur par le chemin générique, lire son schéma ---
//   NB : Apple expose l'identifier en string numérique ("0".."6") et le label dans displayName
//   → on garde l'identifier comme clé stable, displayName comme nom lisible (exactement notre schema).
// (la réf au nœud doit rester vivante le temps de lire parameterTree — sinon ARC le libère)
guard let probeNode = makeAU("dcmp"), let probeTree = probeNode.auAudioUnit.parameterTree else {
    print("ÉCHEC : impossible d'instancier AUDynamicsProcessor (dcmp) par le chemin générique"); exit(1)
}
print("AU instanciée : AUDynamicsProcessor — params auto-décrits via AUParameterTree :")
for p in probeTree.allParameters {
    print(String(format: "  id='%@'  name='%@'  [%.2f … %.2f] def=%.2f",
                 p.identifier as NSString, p.displayName as NSString, p.minValue, p.maxValue, p.value))
}

// le param « seuil de compression » (clé = son identifier), trouvé par displayName
func thresholdId(_ tree: AUParameterTree) -> String? {
    tree.allParameters.first { $0.displayName.localizedCaseInsensitiveContains("threshold") }?.identifier
}
guard let thrId = thresholdId(probeTree) else { print("ÉCHEC : pas de param threshold"); exit(1) }

// --- 2) construire un compresseur réglé via l'identifier, comme le ferait applyInsertParams ---
func compressor(threshold: Float) -> AVAudioUnit {
    let au = makeAU("dcmp")!
    let tree = au.auAudioUnit.parameterTree!
    for p in tree.allParameters where p.identifier == thrId { p.value = threshold }   // réglage PAR identifier
    return au
}

// --- 3) isoler l'effet DU PARAMÈTRE : seuil haut (pas de compression) vs seuil bas (compression franche) ---
let lA = Int(0.10 * sr), lB = Int(0.40 * sr), qA = Int(0.60 * sr), qB = Int(0.90 * sr)
func gap(_ x: [Float]) -> Double { rmsDB(x, lA, lB) - rmsDB(x, qA, qB) }   // écart loud-quiet (dB)

let gapDry  = gap(render(through: nil))
let gapHigh = gap(render(through: compressor(threshold: 20)))    // seuil +20 dB : au-dessus du signal → ~aucune compression
let gapLow  = gap(render(through: compressor(threshold: -40)))   // seuil -40 dB : tout compressé fort
let controlled = gapHigh - gapLow

print(String(format: "\nécart dynamique loud-quiet :"))
print(String(format: "  à sec                 %.1f dB", gapDry))
print(String(format: "  seuil +20 dB (off)    %.1f dB", gapHigh))
print(String(format: "  seuil -40 dB (on)     %.1f dB", gapLow))
print(String(format: "→ le seul changement du paramètre threshold réduit la dynamique de %.1f dB", controlled))

// si le PARAMÈTRE (et pas juste l'insertion) pilote le DSP, passer le seuil de +20 à -40 doit compresser nettement
if controlled >= 6 && gapHigh > gapLow {
    print("\nPASS ✓  le paramètre générique (réglé par identifier) atteint bien le DSP")
} else {
    print("\nFAIL ✗  le paramètre n'a pas l'effet attendu (Δ=\(controlled) dB)")
    exit(1)
}
