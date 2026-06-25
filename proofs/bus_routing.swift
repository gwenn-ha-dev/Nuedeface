// Nuedeface — proof : graphe de bus (sous-mix de groupe). pistes → sous-bus → master → sortie.
//   swiftc proofs/bus_routing.swift -o /tmp/bus && /tmp/bus
//
// Vérifie la topologie d'Engine.render généralisée : deux pistes routées vers un MÊME sous-bus,
// lui-même routé vers master. (1) le GAIN du sous-bus atténue les deux pistes ensemble ;
// (2) un INSERT sur le sous-bus (limiteur) agit sur la somme du groupe.

import Foundation
import AVFoundation

let sr = 48_000.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
let N = Int(sr)

func tone(_ amp: Float, _ hz: Float) -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(N))!; b.frameLength = AVAudioFrameCount(N)
    for i in 0..<N { let s = amp * sinf(2 * .pi * hz * Float(i) / Float(sr)); b.floatChannelData![0][i] = s; b.floatChannelData![1][i] = s }
    return b
}
func makeAU(_ sub: String) -> AVAudioUnit? {
    func cc(_ s: String) -> OSType { var x = Array(s.utf8.prefix(4)); while x.count<4 {x.append(0x20)}; return x.reduce(OSType(0)){($0<<8)|OSType($1)} }
    return AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: cc(sub), componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
}

// 2 pistes (amp, hz) → sous-bus (gain `busGain`, + limiteur optionnel) → master → sortie. Renvoie le peak.
func render(_ tracks: [(Float, Float)], busGain: Float, limiter: Bool) -> Float {
    let engine = AVAudioEngine()
    let subBus = AVAudioMixerNode(); let master = AVAudioMixerNode()
    engine.attach(subBus); engine.attach(master)
    var players: [AVAudioPlayerNode] = []
    for (amp, hz) in tracks {
        let p = AVAudioPlayerNode(); engine.attach(p)
        engine.connect(p, to: subBus, format: fmt)      // les deux pistes somment dans le sous-bus
        p.scheduleBuffer(tone(amp, hz), at: nil, completionHandler: nil); players.append(p)
    }
    var up: AVAudioNode = subBus
    if limiter, let lim = makeAU("lmtr") { engine.attach(lim); engine.connect(up, to: lim, format: fmt); up = lim }
    engine.connect(up, to: master, format: fmt)         // sous-bus → master
    engine.connect(master, to: engine.mainMixerNode, format: fmt)
    subBus.outputVolume = busGain; master.outputVolume = 1; engine.mainMixerNode.outputVolume = 1

    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
    try! engine.start()
    for p in players { p.play() }
    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    var peak: Float = 0; var done = 0
    while done < N {
        guard (try? engine.renderOffline(512, to: out)) == .success else { break }
        let l = out.floatChannelData![0], r = out.floatChannelData![1]
        for i in 0..<Int(out.frameLength) { peak = max(peak, abs(l[i]), abs(r[i])) }
        done += Int(out.frameLength)
    }
    engine.stop(); return peak
}

// (1) gain du sous-bus : deux pistes à 0.3 → sous-bus 1.0 vs 0.5
let full = render([(0.3, 220), (0.3, 440)], busGain: 1.0, limiter: false)
let half = render([(0.3, 220), (0.3, 440)], busGain: 0.5, limiter: false)
print(String(format: "sous-bus gain 1.0 → peak %.3f | gain 0.5 → peak %.3f (ratio %.2f, attendu ~0.5)", full, half, half/full))
let gainOK = abs(half/full - 0.5) < 0.05

// (2) insert (limiteur) sur le sous-bus : deux pistes fortes (somme > 0 dBFS) plafonnées en groupe
let noLim = render([(0.7, 220), (0.7, 440)], busGain: 1.0, limiter: false)
let withLim = render([(0.7, 220), (0.7, 440)], busGain: 1.0, limiter: true)
print(String(format: "groupe sans limiteur → peak %.3f (clippe: %@) | avec limiteur de bus → peak %.3f", noLim, noLim >= 1.0 ? "oui" : "non", withLim))
let fxOK = noLim >= 1.0 && withLim < 1.0

if gainOK && fxOK { print("\nPASS ✓  le sous-bus somme le groupe, son gain et ses inserts agissent sur l'ensemble") }
else { print("\nFAIL ✗  gain=\(gainOK) fx=\(fxOK)"); exit(1) }
