// Nuedeface — proof keystone : log d'ops → fold → reconcile → moteur vivant → undo.
//
// Le cœur du modèle "document autoritaire" du concept, jamais exercé jusqu'ici :
//   - l'état = le FOLD d'un log de deltas (pas une mutation en place) ;
//   - un RECONCILER projette le document sur les nœuds AVAudioEngine ;
//   - l'audio rendu doit REFLÉTER le document à chaque étape ;
//   - UNDO = drop du dernier delta + refold + reconcile (undo "gratuit" annoncé).
//
//   swiftc proofs/reconcile.swift -o /tmp/reconcile && /tmp/reconcile

import AVFoundation

let sr = 48_000.0
let block: AVAudioFrameCount = 512
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

// --- une tranche minimale de l'arbre du document ---
struct Doc {
    var trackGain: Float = 1.0    // track/t1/controls/gain (base)
    var eqGain: Float = 0.0       // track/t1/fx/i1/params/gain (dB, parametrique @220 Hz)
    var eqBypass: Bool = false    // track/t1/fx/i1/bypass
}

enum Delta: CustomStringConvertible {
    case setTrackGain(Float), setEqGain(Float), setEqBypass(Bool)
    var description: String {
        switch self {
        case .setTrackGain(let v): return "set track/t1/controls/gain = \(v)"
        case .setEqGain(let v):    return "set track/t1/fx/i1/params/gain = \(v) dB"
        case .setEqBypass(let v):  return "set track/t1/fx/i1/bypass = \(v)"
        }
    }
}

// FOLD : reconstruit le document depuis le log (last-write-wins par champ).
func fold(_ log: [Delta]) -> Doc {
    var d = Doc()
    for delta in log {
        switch delta {
        case .setTrackGain(let v): d.trackGain = v
        case .setEqGain(let v):    d.eqGain = v
        case .setEqBypass(let v):  d.eqBypass = v
        }
    }
    return d
}

// --- moteur + RECONCILER : projette un Doc sur les nœuds vivants ---
final class MixEngine {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 1)
    let tmix = AVAudioMixerNode()
    let out: AVAudioPCMBuffer

    init() {
        engine.attach(player); engine.attach(eq); engine.attach(tmix)
        engine.connect(player, to: eq, format: fmt)
        engine.connect(eq, to: tmix, format: fmt)
        engine.connect(tmix, to: engine.mainMixerNode, format: fmt)
        let band = eq.bands[0]
        band.filterType = .parametric; band.frequency = 220; band.bandwidth = 1.0
        try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
        try! engine.start()
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr))!
        buf.frameLength = AVAudioFrameCount(sr)
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(sr) { p[i] = Float(0.3 * sin(2.0 * .pi * 220.0 * Double(i) / sr)) }
        }
        player.scheduleBuffer(buf, at: nil, options: .loops)
        player.play()
        out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!
    }

    // LE reconciler : document -> propriétés des nœuds.
    func reconcile(_ doc: Doc) {
        tmix.outputVolume = doc.trackGain
        eq.bands[0].gain = doc.eqGain
        eq.bands[0].bypass = doc.eqBypass
    }

    // niveau de sortie après reconcile (dBFS RMS, ÉTAT STATIONNAIRE).
    // On jette un warm-up pour laisser le lissage de paramètre se stabiliser avant de mesurer.
    func renderDBFS(seconds: Double = 1.0, warmup: Double = 0.3) -> Double {
        var warm = Int(warmup * sr)
        while warm > 0 {
            guard (try? engine.renderOffline(block, to: out)) == .success else { break }
            warm -= Int(out.frameLength)
        }
        var sum = 0.0; var n = 0
        let total = Int(seconds * sr)
        while n < total {
            guard (try? engine.renderOffline(block, to: out)) == .success else { break }
            let l = out.floatChannelData![0], r = out.floatChannelData![1]
            for i in 0..<Int(out.frameLength) {
                sum += Double(l[i])*Double(l[i]) + Double(r[i])*Double(r[i]); n += 1
            }
        }
        let rms = (sum / Double(2 * n)).squareRoot()
        return 20 * log10(rms)
    }
}

// ---------------------------------------------------------------------------

let eng = MixEngine()
var log = [Delta]()
var ref = 0.0

func step(_ title: String) {
    let doc = fold(log)              // état = fold du log, jamais muté en place
    eng.reconcile(doc)              // projeté sur le moteur vivant
    let db = eng.renderDBFS()       // l'audio reflète-t-il le doc ?
    let delta = ref == 0 ? "" : String(format: "  (Δ %+.2f dB)", db - ref)
    print(String(format: "  %-30@ → %6.2f dBFS%@", title as NSString, db, delta))
    ref = db
}

print("=== Nuedeface — proof keystone : reconcile depuis le log ===\n")
print("MUTATE (append au log, refold, reconcile) :")
step("doc vide (gain 1.0, EQ plat)")
log.append(.setTrackGain(0.5));  print("  + \(log.last!)"); step("→ rendu")
log.append(.setEqGain(12));      print("  + \(log.last!)"); step("→ rendu")
log.append(.setEqBypass(true));  print("  + \(log.last!)"); step("→ rendu")

print("\nUNDO (drop du dernier delta, refold, reconcile) :")
log.removeLast(); print("  undo → \(fold(log).eqBypass == false ? "bypass annulé" : "")"); step("→ rendu")
log.removeLast(); print("  undo → EQ gain annulé");  step("→ rendu")
log.removeLast(); print("  undo → track gain annulé"); step("→ rendu")

print("\nVérité : chaque ligne = sortie audio mesurée, pilotée UNIQUEMENT par le fold du log.")
