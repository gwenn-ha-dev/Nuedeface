// Nuedeface — proof : un limiteur sur le BUS MASTER plafonne le peak (mastering bout-en-bout).
//   swiftc proofs/master_limiter.swift -o /tmp/lim && /tmp/lim
//
// Tranche le point dur « chaîne d'inserts sur le master » : la somme des pistes passe par un master mix,
// puis par une chaîne d'inserts (ici AUPeakLimiter "lmtr") avant la sortie. On envoie un signal qui
// dépasse 0 dBFS (somme de pistes), et on vérifie que SANS limiteur ça clippe (peak ≥ 1.0) tandis
// qu'AVEC limiteur réglé le peak repasse SOUS le seuil. Topologie identique à Engine.render :
//   players → masterMix → [inserts master] → mainMixerNode.

import Foundation
import AVFoundation

let sr = 48_000.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
let n = Int(sr)                            // 1 s

// deux « pistes » à 0.7 d'amplitude : leur somme (1.4) dépasse 0 dBFS → écrête sans limiteur
func tone(_ amp: Float) -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
    b.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { let s = amp * sinf(2 * .pi * 220 * Float(i) / Float(sr)); b.floatChannelData![0][i] = s; b.floatChannelData![1][i] = s }
    return b
}

func makeAU(_ subType: String) -> AVAudioUnit? {
    func fourCC(_ s: String) -> OSType { var x = Array(s.utf8.prefix(4)); while x.count<4 {x.append(0x20)}; return x.reduce(OSType(0)){($0<<8)|OSType($1)} }
    let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: fourCC(subType),
                                      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    return AVAudioUnitEffect(audioComponentDescription: d)
}

// render : 2 players → masterMix → [limiteur?] → mainMixer (= la topologie d'Engine.render)
func renderPeak(limiter: AVAudioUnit?) -> Float {
    let engine = AVAudioEngine()
    let masterMix = AVAudioMixerNode(); engine.attach(masterMix)
    var players: [AVAudioPlayerNode] = []
    for amp in [Float(0.7), Float(0.7)] {
        let p = AVAudioPlayerNode(); engine.attach(p)
        engine.connect(p, to: masterMix, format: fmt)
        p.scheduleBuffer(tone(amp), at: nil, completionHandler: nil)
        players.append(p)
    }
    var up: AVAudioNode = masterMix
    if let lim = limiter { engine.attach(lim); engine.connect(up, to: lim, format: fmt); up = lim }
    engine.connect(up, to: engine.mainMixerNode, format: fmt)
    masterMix.outputVolume = 1; engine.mainMixerNode.outputVolume = 1

    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
    try! engine.start()
    for p in players { p.play() }
    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    var peak: Float = 0; var done = 0
    while done < n {
        guard (try? engine.renderOffline(512, to: out)) == .success else { break }
        let l = out.floatChannelData![0], r = out.floatChannelData![1]
        for i in 0..<Int(out.frameLength) { peak = max(peak, abs(l[i]), abs(r[i])) }
        done += Int(out.frameLength)
    }
    engine.stop()
    return peak
}

func db(_ x: Float) -> String { x <= 1e-6 ? "-inf" : String(format: "%+.2f dBFS", 20 * log10(Double(x))) }

// --- sans limiteur : la somme écrête ---
let peakDry = renderPeak(limiter: nil)
print("sans limiteur  : peak = \(String(format: "%.3f", peakDry))  (\(db(peakDry)))  clipping=\(peakDry >= 1.0)")

// --- avec AUPeakLimiter réglé (preGain 0, on baisse le seuil via la réduction de gain interne) ---
guard let lim = makeAU("lmtr"), let tree = lim.auAudioUnit.parameterTree else {
    print("ÉCHEC : AUPeakLimiter (lmtr) indisponible"); exit(1)
}
print("\nlimiteur instancié : AUPeakLimiter — params :")
for p in tree.allParameters { print(String(format: "  id='%@' name='%@' [%.3f … %.3f] def=%.3f", p.identifier as NSString, p.displayName as NSString, p.minValue, p.maxValue, p.value)) }
// attaque rapide pour bien plafonner le sinus
for p in tree.allParameters where p.displayName.localizedCaseInsensitiveContains("attack") { p.value = max(p.minValue, 0.001) }

let peakWet = renderPeak(limiter: lim)
print("\navec limiteur  : peak = \(String(format: "%.3f", peakWet))  (\(db(peakWet)))  clipping=\(peakWet >= 1.0)")

// le limiteur sur le master doit ramener le peak sous 0 dBFS (et sous le cas non-limité)
if peakDry >= 1.0 && peakWet < 1.0 && peakWet < peakDry {
    print("\nPASS ✓  la chaîne d'inserts du master plafonne le peak (\(db(peakDry)) → \(db(peakWet)))")
} else {
    print("\nFAIL ✗  le limiteur de bus n'a pas plafonné (dry \(db(peakDry)), wet \(db(peakWet)))")
    exit(1)
}
