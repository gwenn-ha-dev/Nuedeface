// Nuedeface — proof : sends (taps parallèles vers un bus aux), pré vs post-fader.
//   swiftc proofs/sends.swift -o /tmp/sends && /tmp/sends
//
// Un send prélève une copie du signal et l'ajoute à un bus aux. POST-fader : tap après le fader de la piste
// (suit le fader → fader à 0 ⇒ send muet). PRÉ-fader : tap avant le fader (indépendant → passe même fader à 0).
// On le vérifie via la connexion multi-points d'AVAudioEngine (le fan-out d'Engine.fanout).

import Foundation
import AVFoundation

let sr = 48_000.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
let N = Int(sr)

func tone() -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(N))!; b.frameLength = AVAudioFrameCount(N)
    for i in 0..<N { let s: Float = 0.5 * sinf(2 * .pi * 330 * Float(i) / Float(sr)); b.floatChannelData![0][i] = s; b.floatChannelData![1][i] = s }
    return b
}

// player → trackMix(fader) → master ; + un send (pré ou post) → aux → master. Renvoie le peak du master.
func render(fader: Float, sendLevel: Float, pre: Bool) -> Float {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode(), trackMix = AVAudioMixerNode(), aux = AVAudioMixerNode(), sendGain = AVAudioMixerNode()
    for n in [player, trackMix, aux, sendGain] { engine.attach(n) }
    trackMix.outputVolume = fader; aux.outputVolume = 1; sendGain.outputVolume = sendLevel
    engine.connect(sendGain, to: aux, format: fmt)
    // aux et le chemin principal entrent dans master sur des bus d'entrée DISTINCTS (sinon collision → un seul survit)
    engine.connect(aux, to: engine.mainMixerNode, fromBus: 0, toBus: 1, format: fmt)
    let send = AVAudioConnectionPoint(node: sendGain, bus: 0)
    if pre {   // tap pré-fader : player → [trackMix, sendGain] ; trackMix → master (bus 0)
        engine.connect(player, to: [AVAudioConnectionPoint(node: trackMix, bus: 0), send], fromBus: 0, format: fmt)
        engine.connect(trackMix, to: engine.mainMixerNode, fromBus: 0, toBus: 0, format: fmt)
    } else {   // tap post-fader : player → trackMix → [master(bus 0), sendGain]
        engine.connect(player, to: trackMix, format: fmt)
        engine.connect(trackMix, to: [AVAudioConnectionPoint(node: engine.mainMixerNode, bus: 0), send], fromBus: 0, format: fmt)
    }
    engine.mainMixerNode.outputVolume = 1

    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
    try! engine.start(); player.scheduleBuffer(tone(), at: nil, completionHandler: nil); player.play()
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

let mainOnly  = render(fader: 1, sendLevel: 0, pre: false)   // pas de send
let postSend  = render(fader: 1, sendLevel: 1, pre: false)   // send post : s'ajoute
let postF0    = render(fader: 0, sendLevel: 1, pre: false)   // fader 0 : post-send muet
let preF0     = render(fader: 0, sendLevel: 1, pre: true)    // fader 0 : pré-send passe

print(String(format: "principal seul        : peak %.3f", mainOnly))
print(String(format: "+ send post-fader     : peak %.3f  (s'ajoute : %@)", postSend, postSend > mainOnly + 0.3 ? "oui" : "non"))
print(String(format: "fader=0, send post     : peak %.3f  (muet attendu)", postF0))
print(String(format: "fader=0, send PRÉ      : peak %.3f  (passe attendu ~0.5)", preF0))

let adds  = postSend > mainOnly + 0.3
let postFollowsFader = postF0 < 0.05
let preIndependent   = preF0 > 0.4
if adds && postFollowsFader && preIndependent {
    print("\nPASS ✓  le send s'ajoute, le post-fader suit le fader, le pré-fader en est indépendant")
} else {
    print("\nFAIL ✗  adds=\(adds) postSuitFader=\(postFollowsFader) preIndépendant=\(preIndependent)"); exit(1)
}
